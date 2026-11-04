using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RightClip.Core.Media;
using RightClip.Core.Operations;

namespace RightClip.App;

public sealed partial class MainViewModel
{
    private readonly Dictionary<string, TrimTimeline> _timelines = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IReadOnlyList<ImageSource>> _thumbnailCache = new(StringComparer.OrdinalIgnoreCase);
    private MediaFileItem? _selectedFile;
    private TrimTimeline? _timeline;
    private IReadOnlyList<TrimSegment> _timelineSegments = [];
    private IReadOnlyList<ImageSource> _timelineThumbnails = [];
    private CancellationTokenSource? _thumbnailCancellation;
    private double _playheadSeconds;
    private TimeSpan? _selectedCut;
    private string _timelineSummary = "Open a video to start trimming.";
    private string _timelinePreviewStatus = string.Empty;
    private string _exportButtonLabel = "Export clips";
    private string _outputHint = string.Empty;
    private bool _isCompactLayout;
    private bool _isShortLayout;

    public MediaFileItem? SelectedFile
    {
        get => _selectedFile;
        set
        {
            if (IsBusy || !Set(ref _selectedFile, value))
            {
                return;
            }

            RefreshPreviewMedia();
            if (value?.Media is { } media)
            {
                LoadEditors(media);
            }
        }
    }

    public string VideoCountLabel => $"Videos and progress ({Files.Count})";

    public bool HasMultipleVideos => Files.Count > 1;

    public bool IsCompactLayout
    {
        get => _isCompactLayout;
        set
        {
            if (Set(ref _isCompactLayout, value))
            {
                Changed(nameof(ShowTimelineHints));
                Changed(nameof(PreviewHeight));
                Changed(nameof(PreviewWidth));
            }
        }
    }

    public bool IsShortLayout
    {
        get => _isShortLayout;
        set
        {
            if (Set(ref _isShortLayout, value))
            {
                Changed(nameof(PreviewHeight));
                Changed(nameof(PreviewWidth));
            }
        }
    }

    public bool ShowTimelineHints => !IsCompactLayout;

    public bool CanChangeFiles => !IsBusy;

    public bool CanEditTimeline => !IsBusy && IsTrimAction && _timeline is not null;

    public IReadOnlyList<TrimSegment> TimelineSegments { get => _timelineSegments; private set => Set(ref _timelineSegments, value); }

    public IReadOnlyList<ImageSource> TimelineThumbnails { get => _timelineThumbnails; private set => Set(ref _timelineThumbnails, value); }

    public string TimelineSummary { get => _timelineSummary; private set => Set(ref _timelineSummary, value); }

    public string TimelinePreviewStatus { get => _timelinePreviewStatus; private set => Set(ref _timelinePreviewStatus, value); }

    public string ExportButtonLabel { get => _exportButtonLabel; private set => Set(ref _exportButtonLabel, value); }

    public string OutputHint { get => _outputHint; private set => Set(ref _outputHint, value); }

    public string PlayheadTime => MediaTime.Display(TimeSpan.FromSeconds(PlayheadSeconds));

    public double? SelectedCutSeconds => _selectedCut?.TotalSeconds;

    public double PlayheadSeconds
    {
        get => _playheadSeconds;
        set
        {
            var bounded = Math.Clamp(value, 0, PreviewMaximum);
            if (Set(ref _playheadSeconds, bounded))
            {
                Changed(nameof(PlayheadTime));
                RefreshTimelineCommands();
                QueuePreview(bounded);
            }
        }
    }

    public RelayCommand AddCutCommand { get; private set; } = null!;

    public RelayCommand RemoveCutCommand { get; private set; } = null!;

    public RelayCommand ResetCutsCommand { get; private set; } = null!;

    public AsyncRelayCommand ExportClipsCommand { get; private set; } = null!;

    private void InitializeTimelineCommands()
    {
        AddCutCommand = new RelayCommand(() => AddTimelineCut(PlayheadSeconds),
            () => CanEditTimeline && TimelineSegments.Any(segment =>
                TimeSpan.FromSeconds(PlayheadSeconds) > segment.Start && TimeSpan.FromSeconds(PlayheadSeconds) < segment.End));
        RemoveCutCommand = new RelayCommand(() =>
        {
            if (_selectedCut is { } cut)
            {
                EditTimeline(timeline => timeline.RemoveCut(cut));
                _selectedCut = null;
                Changed(nameof(SelectedCutSeconds));
                RefreshTimelineCommands();
            }
        }, () => CanEditTimeline && _selectedCut is not null);
        ResetCutsCommand = new RelayCommand(() =>
        {
            EditTimeline(timeline => timeline.Reset());
            _selectedCut = null;
            Changed(nameof(SelectedCutSeconds));
            RefreshTimelineCommands();
        }, () => CanEditTimeline && TimelineSegments.Count > 1);
        ExportClipsCommand = new AsyncRelayCommand(ExportClipsAsync,
            () => CanEditTimeline && TimelineSegments.Any(segment => segment.IsSelected));
    }

    public void AddTimelineCut(double seconds)
    {
        var position = TimeSpan.FromSeconds(seconds);
        EditTimeline(timeline => timeline.AddCut(position));
        SelectTimelineCut(seconds);
    }

    public void MoveTimelineCut(double originalSeconds, double seconds)
    {
        EditTimeline(timeline => timeline.MoveCut(TimeSpan.FromSeconds(originalSeconds), TimeSpan.FromSeconds(seconds)));
        SelectTimelineCut(seconds);
        PlayheadSeconds = seconds;
    }

    public void RemoveTimelineCut(double seconds)
    {
        EditTimeline(timeline => timeline.RemoveCut(TimeSpan.FromSeconds(seconds)));
        _selectedCut = null;
        Changed(nameof(SelectedCutSeconds));
        RefreshTimelineCommands();
    }

    public void ToggleTimelineSegment(int index) => EditTimeline(timeline => timeline.ToggleSegment(index));

    public void SelectTimelineCut(double seconds)
    {
        var position = TimeSpan.FromSeconds(seconds);
        _selectedCut = TimelineSegments.Take(TimelineSegments.Count - 1).Any(segment => segment.End == position) ? position : null;
        Changed(nameof(SelectedCutSeconds));
        RefreshTimelineCommands();
    }

    public void StopPreviews()
    {
        _previewCancellation?.Cancel();
        _thumbnailCancellation?.Cancel();
    }

    private void EditTimeline(Action<TrimTimeline> edit)
    {
        if (!CanEditTimeline || _timeline is null)
        {
            return;
        }

        try
        {
            edit(_timeline);
            TimelineSegments = _timeline.Segments;
            Summary = string.Empty;
            RefreshTimelineSummary();
            RefreshTimelineCommands();
        }
        catch (InvalidOperationException exception)
        {
            Summary = exception.Message;
        }
    }

    private void SetTimelineMedia(MediaInfo? media)
    {
        _thumbnailCancellation?.Cancel();
        _selectedCut = null;
        Changed(nameof(SelectedCutSeconds));
        TimelineThumbnails = [];
        if (media is null)
        {
            _timeline = null;
            TimelineSegments = [];
            TimelinePreviewStatus = string.Empty;
        }
        else
        {
            if (!_timelines.TryGetValue(media.SourcePath, out _timeline))
            {
                _timeline = new TrimTimeline(media.Duration);
                _timelines.Add(media.SourcePath, _timeline);
            }

            TimelineSegments = _timeline.Segments;
            if (IsTrimAction)
            {
                if (_thumbnailCache.TryGetValue(media.SourcePath, out var thumbnails))
                {
                    TimelineThumbnails = thumbnails;
                    TimelinePreviewStatus = "Full video timeline";
                }
                else
                {
                    _thumbnailCancellation = new CancellationTokenSource();
                    _ = LoadTimelineThumbnailsAsync(media, _thumbnailCancellation);
                }
            }
        }

        PlayheadSeconds = 0;
        Changed(nameof(CanEditTimeline));
        RefreshTimelineSummary();
        RefreshTimelineCommands();
    }

    private void RefreshTimelineCommands()
    {
        AddCutCommand.RaiseCanExecuteChanged();
        RemoveCutCommand.RaiseCanExecuteChanged();
        ResetCutsCommand.RaiseCanExecuteChanged();
        ExportClipsCommand.RaiseCanExecuteChanged();
    }

    private void RefreshTimelineSummary()
    {
        var selected = TimelineSegments.Where(segment => segment.IsSelected).ToArray();
        ExportButtonLabel = selected.Length == 1 ? "Export clip" : $"Export {selected.Length} clips";
        TimelineSummary = _timeline is null ? "Open a video to start trimming." :
            $"{selected.Length} of {TimelineSegments.Count} clips selected · {MediaTime.Display(TimeSpan.FromTicks(selected.Sum(segment => segment.Duration.Ticks)))} to export";
        var allocator = new OutputAllocator();
        OutputHint = SelectedFile?.Media is not { } media ? string.Empty :
            string.Join(" · ", selected.Select((_, index) => Path.GetFileName(allocator.Allocate(media.SourcePath, $".clip{index + 1:00}"))));
    }

    private async Task LoadTimelineThumbnailsAsync(MediaInfo media, CancellationTokenSource cancellation)
    {
        try
        {
            TimelinePreviewStatus = "Loading the full video timeline";
            var bytes = await _services.Preview.ReadTimelineAsync(media, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            var strip = CreateImage(bytes);
            var images = new List<ImageSource>();
            for (var index = 0; index < PreviewService.ThumbnailCount; index++)
            {
                var image = new CroppedBitmap(strip, new Int32Rect(index * PreviewService.ThumbnailWidth, 0,
                    PreviewService.ThumbnailWidth, PreviewService.ThumbnailHeight));
                image.Freeze();
                images.Add(image);
            }

            TimelineThumbnails = images;
            _thumbnailCache[media.SourcePath] = images;
            TimelinePreviewStatus = "Full video timeline";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (ReferenceEquals(_thumbnailCancellation, cancellation))
            {
                TimelinePreviewStatus = $"Timeline thumbnails unavailable: {FirstLine(exception.Message)}";
            }
        }
        finally
        {
            if (ReferenceEquals(_thumbnailCancellation, cancellation))
            {
                _thumbnailCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    private async Task ExportClipsAsync()
    {
        if (SelectedFile?.Media is not { } media || !CanEditTimeline)
        {
            return;
        }

        var segments = TimelineSegments;
        IsBusy = true;
        _cancellation = new CancellationTokenSource();
        BusyStatus = "Preparing selected clips";
        Summary = string.Empty;
        try
        {
            var plans = await _services.Trim.CreateClipPlansAsync(media, segments, new OutputAllocator(),
                (CutEncoding)SelectedCutEncodingIndex, _cancellation.Token);
            if (SelectedCutEncodingIndex == (int)CutEncoding.FastCopy &&
                !Confirm([new ReviewGroup
                {
                    FileName = Path.GetFileName(media.SourcePath),
                    Summary = "Fast stream copy · check the landed start of each clip",
                    Items = plans.Select((plan, index) => new ReviewItem
                    {
                        Title = $"Clip {index + 1}",
                        Timing = $"Requested {MediaTime.Display(plan.RequestedStart)} · landed {MediaTime.Display(plan.LandedStart)} · end {MediaTime.Display(plan.RequestedEnd)}",
                        OutputPath = plan.OutputPath
                    }).ToArray()
                }], "Fast copy can include frames before your cut marks."))
            {
                return;
            }

            BusyStatus = "Exporting selected clips";
            var file = SelectedFile;
            var progress = new Progress<OperationProgress>(update =>
            {
                if (file is not null)
                {
                    file.Status = update.Status;
                    if (update.Fraction is { } fraction)
                    {
                        file.Progress = fraction;
                    }
                }
                UpdateOperation(update);
            });
            BeginOperation($"Writing {plans.Count} selected clips");
            ApplyResults(await _services.Trim.RunClipsAsync(plans, progress, _cancellation.Token));
        }
        catch (OperationCanceledException)
        {
            Summary = "Export cancelled. No clips were kept.";
        }
        catch (Exception exception)
        {
            Summary = exception.Message;
            MessageBox.Show(Application.Current.MainWindow, exception.Message, "RightClip could not export these clips",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            CloseOperationWindow();
            _cancellation.Dispose();
            _cancellation = null;
            IsBusy = false;
            BusyStatus = "Ready";
        }
    }
}
