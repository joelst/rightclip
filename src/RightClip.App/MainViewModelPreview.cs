using System.IO;
using System.Windows.Media;
using RightClip.Core.Media;

namespace RightClip.App;

public sealed partial class MainViewModel
{
    private MediaInfo? _previewMedia;
    private CancellationTokenSource? _previewCancellation;
    private double _previewMaximum;
    private double _trimStartSeconds;
    private double _trimEndSeconds;
    private bool _syncingTimeFields;
    private ImageSource? _previewImage;
    private string _previewStatus = "Add a video to see frame previews.";
    private double _previewAspectRatio = 16d / 9d;

    public double PreviewMaximum { get => _previewMaximum; private set => Set(ref _previewMaximum, value); }

    public double PreviewHeight => IsShortLayout ? 0 : IsCompactLayout ? 120 : 180;

    public double PreviewAspectRatio
    {
        get => _previewAspectRatio;
        private set
        {
            if (Set(ref _previewAspectRatio, value))
            {
                Changed(nameof(PreviewWidth));
            }
        }
    }

    public double PreviewWidth => PreviewHeight * PreviewAspectRatio;

    public double TrimStartSeconds
    {
        get => _trimStartSeconds;
        set
        {
            if (_syncingTimeFields)
            {
                return;
            }

            var bounded = Math.Clamp(value, 0, PreviewMaximum);
            if (!Set(ref _trimStartSeconds, bounded))
            {
                return;
            }

            _syncingTimeFields = true;
            StartInput = MediaTime.FFmpeg(TimeSpan.FromSeconds(bounded));
            _syncingTimeFields = false;
            SelectedTimeKindIndex = 1;
            QueuePreview(bounded);
        }
    }

    public double TrimEndSeconds
    {
        get => _trimEndSeconds;
        set
        {
            if (_syncingTimeFields)
            {
                return;
            }

            var bounded = Math.Clamp(value, 0, PreviewMaximum);
            if (!Set(ref _trimEndSeconds, bounded))
            {
                return;
            }

            _syncingTimeFields = true;
            EndInput = MediaTime.FFmpeg(TimeSpan.FromSeconds(bounded));
            _syncingTimeFields = false;
            SelectedTimeKindIndex = 1;
            QueuePreview(bounded);
        }
    }

    public ImageSource? PreviewImage { get => _previewImage; private set => Set(ref _previewImage, value); }

    public string PreviewStatus { get => _previewStatus; private set => Set(ref _previewStatus, value); }

    private void SyncStartFromText()
    {
        if (!_syncingTimeFields && MediaTime.TryParse(StartInput, out var time))
        {
            var bounded = Math.Clamp(time.TotalSeconds, 0, PreviewMaximum);
            if (Set(ref _trimStartSeconds, bounded, nameof(TrimStartSeconds)))
            {
                QueuePreview(bounded);
            }
        }
    }

    private void SyncEndFromText()
    {
        if (!_syncingTimeFields && MediaTime.TryParse(EndInput, out var time))
        {
            var bounded = Math.Clamp(time.TotalSeconds, 0, PreviewMaximum);
            if (Set(ref _trimEndSeconds, bounded, nameof(TrimEndSeconds)))
            {
                QueuePreview(bounded);
            }
        }
    }

    private void PreviewModeChanged()
    {
        PlayheadSeconds = SelectedTrimModeIndex == 1 ? TrimEndSeconds : TrimStartSeconds;
    }

    private void RefreshPreviewMedia()
    {
        var media = SelectedFile?.Media;
        if (!ReferenceEquals(media, _previewMedia))
        {
            SetPreviewMedia(media);
        }
    }

    private void SetPreviewMedia(MediaInfo? media)
    {
        _previewCancellation?.Cancel();
        _previewMedia = media;
        PreviewImage = null;
        var video = media?.PrimaryVideo;
        var swapDimensions = (video?.Rotation ?? 0) % 180 is 90 or -90;
        PreviewAspectRatio = video is { Width: > 0, Height: > 0 }
            ? swapDimensions
                ? (double)video.Height.Value / video.Width.Value
                : (double)video.Width.Value / video.Height.Value
            : 16d / 9d;
        if (media is null)
        {
            PreviewMaximum = 0;
            PreviewStatus = "Add a video to see frame previews.";
            SetTimelineMedia(null);
            return;
        }

        PreviewMaximum = Math.Max(0, media.Duration.TotalSeconds);
        SyncStartFromText();
        SyncEndFromText();
        SetTimelineMedia(media);
        QueuePreview(PlayheadSeconds, immediate: true);
    }

    private void QueuePreview(double seconds, bool immediate = false)
    {
        if (_previewMedia is null || PreviewMaximum <= 0 || !IsTrimAction)
        {
            return;
        }

        _previewCancellation?.Cancel();
        _previewCancellation = new CancellationTokenSource();
        _ = LoadPreviewAsync(_previewMedia, seconds, immediate, _previewCancellation);
    }

    private async Task LoadPreviewAsync(MediaInfo media, double seconds, bool immediate, CancellationTokenSource cancellation)
    {
        try
        {
            if (!immediate)
            {
                await Task.Delay(150, cancellation.Token);
            }
            var bounded = Math.Clamp(seconds, 0, media.LastPreviewTime.TotalSeconds);
            var timestamp = TimeSpan.FromSeconds(bounded);
            PreviewStatus = $"Loading frame at {MediaTime.Display(timestamp)}";
            var bytes = await _services.Preview.ReadFrameAsync(media.SourcePath, timestamp, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            PreviewImage = CreateImage(bytes);
            PreviewStatus = $"{Path.GetFileName(media.SourcePath)} · {MediaTime.Display(timestamp)}";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (ReferenceEquals(_previewCancellation, cancellation))
            {
                PreviewStatus = $"Preview unavailable: {FirstLine(exception.Message)}";
            }
        }
        finally
        {
            if (ReferenceEquals(_previewCancellation, cancellation))
            {
                _previewCancellation = null;
            }
            cancellation.Dispose();
        }
    }
}
