using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using RightClip.Core;
using RightClip.Core.Media;
using RightClip.Core.Operations;

namespace RightClip.App;

public sealed partial class MainViewModel : ObservableObject
{
    private RightClipServices _services;
    private UserSettings _settings;
    private CancellationTokenSource? _cancellation;
    private int _selectedActionIndex;
    private int _selectedTrimModeIndex;
    private int _selectedTimeKindIndex;
    private int _selectedCutEncodingIndex;
    private int _selectedRotationIndex;
    private int _sceneSensitivity;
    private string _startInput = "5";
    private string _endInput = "10";
    private bool _extractSelectedSubtitles;
    private bool _fastStart;
    private bool _stripLocation;
    private bool _isBusy;
    private string _busyStatus = "Ready";
    private string _summary = "Add one or more MP4, MOV, MKV, or WebM videos.";
    private string? _lastOutput;

    public MainViewModel(UserSettings settings)
    {
        _settings = settings;
        _sceneSensitivity = settings.SceneSensitivity;
        _services = new RightClipServices(settings.FFmpegDirectory);
        ReviewCommand = new AsyncRelayCommand(ReviewAndRunAsync, () => !IsBusy && Files.Any(file => file.Media is not null));
        CancelCommand = new RelayCommand(() => _cancellation?.Cancel(), () => IsBusy);
        Files.CollectionChanged += (_, _) => ReviewCommand.RaiseCanExecuteChanged();
    }

    public ObservableCollection<MediaFileItem> Files { get; } = [];

    public ObservableCollection<TrackRow> TrackRows { get; } = [];

    public ObservableCollection<SubtitleRow> AddedSubtitles { get; } = [];

    public ObservableCollection<TagRow> Tags { get; } = [];

    public ObservableCollection<ChapterRow> Chapters { get; } = [];

    public AsyncRelayCommand ReviewCommand { get; }

    public RelayCommand CancelCommand { get; }

    public int SelectedActionIndex { get => _selectedActionIndex; set => Set(ref _selectedActionIndex, value); }

    public int SelectedTrimModeIndex
    {
        get => _selectedTrimModeIndex;
        set
        {
            if (Set(ref _selectedTrimModeIndex, value))
            {
                Changed(nameof(StartLabel));
                Changed(nameof(EndLabel));
                Changed(nameof(IsStartInputEnabled));
                Changed(nameof(IsEndInputEnabled));
                Changed(nameof(IsTimeKindEnabled));
                Changed(nameof(IsSceneMode));
                PreviewModeChanged();
            }
        }
    }

    public int SelectedTimeKindIndex { get => _selectedTimeKindIndex; set => Set(ref _selectedTimeKindIndex, value); }

    public int SelectedCutEncodingIndex { get => _selectedCutEncodingIndex; set => Set(ref _selectedCutEncodingIndex, value); }

    public int SelectedRotationIndex { get => _selectedRotationIndex; set => Set(ref _selectedRotationIndex, value); }

    public int SceneSensitivity { get => _sceneSensitivity; set => Set(ref _sceneSensitivity, value); }

    public string StartInput
    {
        get => _startInput;
        set
        {
            if (Set(ref _startInput, value))
            {
                SyncStartFromText();
            }
        }
    }

    public string EndInput
    {
        get => _endInput;
        set
        {
            if (Set(ref _endInput, value))
            {
                SyncEndFromText();
            }
        }
    }

    public bool ExtractSelectedSubtitles
    {
        get => _extractSelectedSubtitles;
        set
        {
            if (Set(ref _extractSelectedSubtitles, value))
            {
                Changed(nameof(CanAddSubtitles));
            }
        }
    }

    public bool CanAddSubtitles => !ExtractSelectedSubtitles;

    public bool FastStart { get => _fastStart; set => Set(ref _fastStart, value); }

    public bool StripLocation { get => _stripLocation; set => Set(ref _stripLocation, value); }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (Set(ref _isBusy, value))
            {
                ReviewCommand.RaiseCanExecuteChanged();
                CancelCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BusyStatus { get => _busyStatus; set => Set(ref _busyStatus, value); }

    public string Summary { get => _summary; set => Set(ref _summary, value); }

    public bool HasOutputs => _lastOutput is not null;

    public string? LastOutput => _lastOutput;

    public string? SettingsFFmpegDirectory => _settings.FFmpegDirectory;

    public string StartLabel => SelectedTrimModeIndex switch
    {
        0 => SelectedTimeKindIndex == 0 ? "Duration to remove from start" : "Start clock time",
        2 => "Range start",
        _ => "Start input (not used)"
    };

    public string EndLabel => SelectedTrimModeIndex switch
    {
        1 => SelectedTimeKindIndex == 0 ? "Duration to remove from end" : "End clock time",
        2 => "Range end",
        _ => "End input (not used)"
    };

    public bool IsStartInputEnabled => SelectedTrimModeIndex is 0 or 2;

    public bool IsEndInputEnabled => SelectedTrimModeIndex is 1 or 2;

    public bool IsTimeKindEnabled => SelectedTrimModeIndex is 0 or 1;

    public bool IsSceneMode => SelectedTrimModeIndex == 3;

    public void AddPaths(IEnumerable<string> paths)
    {
        var rejected = new List<string>();
        foreach (var path in paths)
        {
            try
            {
                var source = SupportedMedia.NormalizeSource(path);
                if (Files.Any(file => string.Equals(file.SourcePath, source, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                var item = new MediaFileItem(source);
                Files.Add(item);
                _ = LoadMediaAsync(item);
            }
            catch (Exception exception)
            {
                rejected.Add(exception.Message);
            }
        }

        if (rejected.Count > 0)
        {
            Summary = string.Join(" ", rejected);
        }
    }

    public void RemoveFiles(IEnumerable<MediaFileItem> files)
    {
        if (IsBusy)
        {
            return;
        }

        foreach (var file in files.ToArray())
        {
            Files.Remove(file);
        }

        RefreshPreviewMedia();
        ReviewCommand.RaiseCanExecuteChanged();
    }

    public void UpdateSettings(UserSettings settings)
    {
        _settings = settings;
        SceneSensitivity = settings.SceneSensitivity;
        _services = new RightClipServices(settings.FFmpegDirectory);
        Summary = "Settings saved. Added videos keep their media information; new operations use the selected FFmpeg folder.";
    }

    private async Task LoadMediaAsync(MediaFileItem item)
    {
        try
        {
            item.Media = await _services.Probe.ProbeAsync(item.SourcePath);
            item.Status = $"{MediaTime.Display(item.Media.Duration)} · {item.Media.AudioStreams.Count()} audio tracks · {item.Media.SubtitleStreams.Count()} subtitles";
            RefreshPreviewMedia();
            if (TrackRows.Count == 0)
            {
                LoadEditors(item.Media);
            }
        }
        catch (Exception exception)
        {
            item.Status = $"Could not read file: {FirstLine(exception.Message)}";
        }
        finally
        {
            ReviewCommand.RaiseCanExecuteChanged();
        }
    }

    private void LoadEditors(MediaInfo media)
    {
        foreach (var stream in media.Streams.Where(stream => stream.CodecType is "audio" or "subtitle"))
        {
            TrackRows.Add(new TrackRow(stream));
        }

        Tags.Clear();
        foreach (var tag in media.Tags)
        {
            Tags.Add(new TagRow(tag.Key, tag.Value));
        }

        EnsureCommonTags();
        Chapters.Clear();
        foreach (var chapter in media.Chapters)
        {
            Chapters.Add(new ChapterRow(MediaTime.Display(chapter.Start), MediaTime.Display(chapter.End), chapter.Title));
        }

        SelectedRotationIndex = media.PrimaryVideo?.Rotation switch
        {
            0 => 1,
            90 => 2,
            180 => 3,
            270 => 4,
            _ => 0
        };
    }

    private void EnsureCommonTags()
    {
        foreach (var key in new[] { "title", "artist", "album", "comment", "copyright", "creation_time" })
        {
            if (!Tags.Any(tag => string.Equals(tag.Key, key, StringComparison.OrdinalIgnoreCase)))
            {
                Tags.Add(new TagRow(key));
            }
        }
    }

    private async Task ReviewAndRunAsync()
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        BusyStatus = "Preparing a review";
        Summary = string.Empty;
        _cancellation = new CancellationTokenSource();
        try
        {
            var media = Files.Where(file => file.Media is not null).Select(file => file.Media!).ToArray();
            var progress = new Progress<OperationProgress>(update =>
            {
                var file = Files.FirstOrDefault(item => string.Equals(item.SourcePath, update.SourcePath, StringComparison.OrdinalIgnoreCase));
                if (file is not null)
                {
                    file.Status = update.Status;
                    if (update.Fraction is { } fraction)
                    {
                        file.Progress = fraction;
                    }
                }
            });

            IReadOnlyList<FileOperationResult> results;
            if (SelectedActionIndex == 0 && SelectedTrimModeIndex == 3)
            {
                BusyStatus = "Detecting scenes and creating thumbnails";
                _settings = _settings with { SceneSensitivity = SceneSensitivity };
                SettingsStore.Save(_settings);
                var outputs = new OutputAllocator();
                var (plans, failures) = await PlanIndividuallyAsync(media,
                    async item => (await _services.Scenes.CreatePlansAsync([item], SceneSensitivity, outputs, _cancellation.Token,
                        (CutEncoding)SelectedCutEncodingIndex)).Single(),
                    _cancellation.Token);
                var groups = plans.Select(plan => new ReviewGroup
                {
                    FileName = Path.GetFileName(plan.Media.SourcePath),
                    Summary = $"{plan.Clips.Count} clips · sensitivity {SceneSensitivity} / 100",
                    Items = plan.Clips.Select(clip => new ReviewItem
                    {
                        Thumbnail = CreateImage(clip.Thumbnail),
                        Title = $"Clip {clip.Number}",
                        Timing = $"Requested {MediaTime.Display(clip.RequestedStart)} · landed {MediaTime.Display(clip.LandedStart)} · end {MediaTime.Display(clip.End)}",
                        OutputPath = clip.OutputPath
                    }).ToArray()
                }).ToArray();
                if (!Confirm(groups, $"Scene review: {plans.Sum(plan => plan.Clips.Count)} clips across {plans.Count} videos. {ReviewSummary(plans.Count, failures.Count)}"))
                {
                    return;
                }

                results = failures.Concat(await _services.Scenes.RunAsync(plans, progress, _cancellation.Token)).ToArray();
            }
            else if (SelectedActionIndex == 0)
            {
                var request = BuildTrimRequest();
                var outputs = new OutputAllocator();
                IReadOnlyList<TrimFilePlan> plans;
                IReadOnlyList<FileOperationResult> failures;
                if ((request.Mode == TrimMode.Start && request.StartKind == TimeInputKind.DurationOffset) ||
                    (request.Mode == TrimMode.End && request.EndKind == TimeInputKind.DurationOffset))
                {
                    (plans, failures) = await PlanIndividuallyAsync(media,
                        async item => (await _services.Trim.CreatePlansAsync([item], request, outputs, _cancellation.Token)).Single(),
                        _cancellation.Token);
                }
                else
                {
                    plans = await _services.Trim.CreatePlansAsync(media, request, outputs, _cancellation.Token);
                    failures = [];
                }

                var groups = plans.Select(plan => new ReviewGroup
                {
                    FileName = Path.GetFileName(plan.Media.SourcePath),
                    Summary = plan.Encoding == CutEncoding.KeyframeSafe
                        ? "Keyframe-safe re-encode · one new sibling file"
                        : "Fast stream copy · one new sibling file",
                    Items =
                    [
                        new ReviewItem
                        {
                            Title = "Trimmed output",
                            Timing = $"Requested start {MediaTime.Display(plan.RequestedStart)} → landed {MediaTime.Display(plan.LandedStart)} · requested end {MediaTime.Display(plan.RequestedEnd)}",
                            OutputPath = plan.OutputPath
                        }
                    ]
                }).ToArray();
                if (!Confirm(groups, $"Check every landed keyframe and output name before writing. {ReviewSummary(plans.Count, failures.Count)}"))
                {
                    return;
                }

                results = failures.Concat(await _services.Trim.RunAsync(plans, progress, _cancellation.Token)).ToArray();
            }
            else if (SelectedActionIndex == 1)
            {
                var request = BuildTrackRequest();
                var (plans, failures) = PlanIndividually(media, item => _services.Tracks.CreatePlans([item], request, new OutputAllocator()).Single());
                var groups = plans.Select(plan => new ReviewGroup
                {
                    FileName = Path.GetFileName(plan.Media.SourcePath),
                    Summary = request.ExtractSelectedSubtitles ? $"{plan.Extractions.Count} subtitle exports" : "Audio tracks and soft subtitles · remux",
                    Items = request.ExtractSelectedSubtitles
                        ? plan.Extractions.Select(extraction => new ReviewItem { Title = extraction.Stream.DisplayName, OutputPath = extraction.OutputPath }).ToArray()
                        : [new ReviewItem { Title = "Remuxed output", OutputPath = plan.OutputPath ?? string.Empty }]
                }).ToArray();
                if (!Confirm(groups, ReviewSummary(plans.Count, failures.Count)))
                {
                    return;
                }

                results = failures.Concat(await _services.Tracks.RunAsync(plans, request, progress, _cancellation.Token)).ToArray();
            }
            else
            {
                var request = BuildDetailsRequest();
                var (plans, failures) = PlanIndividually(media, item => _services.Details.CreatePlans([item], request, new OutputAllocator()).Single());
                var groups = plans.Select(plan => new ReviewGroup
                {
                    FileName = Path.GetFileName(plan.Media.SourcePath),
                    Summary = $"{request.Chapters.Count} chapters · metadata remux",
                    Items = [new ReviewItem { Title = "Details output", OutputPath = plan.OutputPath }]
                }).ToArray();
                if (!Confirm(groups, ReviewSummary(plans.Count, failures.Count)))
                {
                    return;
                }

                results = failures.Concat(await _services.Details.RunAsync(plans, request, progress, _cancellation.Token)).ToArray();
            }

            ApplyResults(results);
        }
        catch (OperationCanceledException)
        {
            Summary = "Preparation cancelled. No reviewed outputs were started.";
        }
        catch (Exception exception)
        {
            Summary = exception.Message;
            MessageBox.Show(Application.Current.MainWindow, exception.Message, "RightClip could not prepare this operation", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _cancellation.Dispose();
            _cancellation = null;
            IsBusy = false;
            BusyStatus = "Ready";
        }
    }

    private (IReadOnlyList<T> Plans, IReadOnlyList<FileOperationResult> Failures) PlanIndividually<T>(
        IReadOnlyList<MediaInfo> mediaFiles,
        Func<MediaInfo, T> createPlan)
    {
        var plans = new List<T>();
        var failures = new List<FileOperationResult>();
        foreach (var media in mediaFiles)
        {
            try
            {
                plans.Add(createPlan(media));
            }
            catch (Exception exception)
            {
                failures.Add(new FileOperationResult(media.SourcePath, false, [], exception.Message));
            }
        }

        if (plans.Count == 0)
        {
            throw new InvalidOperationException(string.Join(" ", failures.Select(failure => failure.Error)));
        }

        return (plans, failures);
    }

    private static async Task<(IReadOnlyList<T> Plans, IReadOnlyList<FileOperationResult> Failures)> PlanIndividuallyAsync<T>(
        IReadOnlyList<MediaInfo> mediaFiles,
        Func<MediaInfo, Task<T>> createPlan,
        CancellationToken cancellationToken)
    {
        var plans = new List<T>();
        var failures = new List<FileOperationResult>();
        foreach (var media in mediaFiles)
        {
            try
            {
                plans.Add(await createPlan(media));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                failures.Add(new FileOperationResult(media.SourcePath, false, [], exception.Message));
            }
        }

        if (plans.Count == 0)
        {
            throw new InvalidOperationException(string.Join(" ", failures.Select(failure => failure.Error)));
        }

        return (plans, failures);
    }

    private bool Confirm(IReadOnlyList<ReviewGroup> groups, string summary)
    {
        if (groups.Count == 0)
        {
            return false;
        }

        BusyStatus = "Waiting for review";
        var review = new ReviewWindow(groups, summary) { Owner = Application.Current.MainWindow };
        var accepted = review.ShowDialog() == true;
        if (!accepted)
        {
            Summary = "Cancelled. No files were written.";
        }
        else
        {
            BusyStatus = "Writing new sibling files";
        }

        return accepted;
    }

    private TrimRequest BuildTrimRequest() => new(
        (TrimMode)SelectedTrimModeIndex,
        MediaTime.Parse(StartInput),
        SelectedTrimModeIndex is 1 or 2 ? MediaTime.Parse(EndInput) : null,
        SelectedTimeKindIndex == 0 ? TimeInputKind.DurationOffset : TimeInputKind.ClockTime,
        SelectedTimeKindIndex == 0 ? TimeInputKind.DurationOffset : TimeInputKind.ClockTime,
        SceneSensitivity,
        (CutEncoding)SelectedCutEncodingIndex);

    private TrackRequest BuildTrackRequest() => new(
        TrackRows.Select(row => new TrackSelection(row.CodecType, row.Ordinal, row.Keep, row.Title)).ToArray(),
        AddedSubtitles.Select(row => new SubtitleInput(row.Path, row.Title, string.IsNullOrWhiteSpace(row.Language) ? null : row.Language.Trim())).ToArray(),
        ExtractSelectedSubtitles);

    private DetailsRequest BuildDetailsRequest()
    {
        var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in Tags.Where(row => !string.IsNullOrWhiteSpace(row.Key)))
        {
            tags[row.Key.Trim()] = row.Value;
        }

        return new DetailsRequest(tags,
            Chapters.Select(chapter => new ChapterInfo(MediaTime.Parse(chapter.Start), MediaTime.Parse(chapter.End), chapter.Title)).ToArray(),
            SelectedRotationIndex == 0 ? null : (SelectedRotationIndex - 1) * 90,
            FastStart,
            StripLocation);
    }

    private void ApplyResults(IReadOnlyList<FileOperationResult> results)
    {
        foreach (var result in results)
        {
            var file = Files.FirstOrDefault(item => string.Equals(item.SourcePath, result.SourcePath, StringComparison.OrdinalIgnoreCase));
            if (file is not null)
            {
                file.Status = result.Succeeded ? "Complete" : result.Cancelled ? "Cancelled" : $"Failed: {FirstLine(result.Error ?? "Unknown error")}";
                file.Progress = result.Succeeded ? 1 : file.Progress;
                file.Outputs = string.Join(Environment.NewLine, result.OutputPaths);
            }
        }

        var successes = results.Where(result => result.Succeeded).ToArray();
        var failures = results.Count - successes.Length;
        _lastOutput = successes.SelectMany(result => result.OutputPaths).LastOrDefault();
        Changed(nameof(HasOutputs));
        Changed(nameof(LastOutput));
        Summary = $"{successes.Length} files completed; {failures} failed or cancelled. {results.Sum(result => result.OutputPaths.Count)} new outputs. Originals were not changed.";
        if (failures > 0)
        {
            Summary += " " + string.Join(" ", results.Where(result => !result.Succeeded).Select(result => $"{Path.GetFileName(result.SourcePath)}: {FirstLine(result.Error ?? "Failed")}"));
        }
    }

    private static string ReviewSummary(int planned, int failed) => failed == 0
        ? $"{planned} videos are ready. No files have been written yet."
        : $"{planned} videos are ready; {failed} files failed planning and will not stop the others.";

    private static BitmapImage CreateImage(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes, false);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static string FirstLine(string value)
    {
        var lines = value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return lines.LastOrDefault() ?? value;
    }
}
