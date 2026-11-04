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

    public double PreviewMaximum { get => _previewMaximum; private set => Set(ref _previewMaximum, value); }

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
        QueuePreview(SelectedTrimModeIndex == 1 ? TrimEndSeconds : TrimStartSeconds);
    }

    private void RefreshPreviewMedia()
    {
        var media = Files.FirstOrDefault(file => file.Media is not null)?.Media;
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
        if (media is null)
        {
            PreviewMaximum = 0;
            PreviewStatus = "Add a video to see frame previews.";
            return;
        }

        PreviewMaximum = Math.Max(0, media.Duration.TotalSeconds);
        var start = MediaTime.TryParse(StartInput, out var requestedStart) ? requestedStart.TotalSeconds : 0;
        var end = MediaTime.TryParse(EndInput, out var requestedEnd) ? requestedEnd.TotalSeconds : PreviewMaximum;
        if (start >= PreviewMaximum || end > PreviewMaximum || start >= end)
        {
            start = PreviewMaximum / 4;
            end = PreviewMaximum;
        }

        TrimStartSeconds = start;
        TrimEndSeconds = end;
        PreviewModeChanged();
    }

    private void QueuePreview(double seconds)
    {
        if (_previewMedia is null || PreviewMaximum <= 0)
        {
            return;
        }

        _previewCancellation?.Cancel();
        _previewCancellation = new CancellationTokenSource();
        _ = LoadPreviewAsync(_previewMedia, seconds, _previewCancellation);
    }

    private async Task LoadPreviewAsync(MediaInfo media, double seconds, CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Delay(150, cancellation.Token);
            var bounded = Math.Clamp(seconds, 0, Math.Max(0, media.Duration.TotalSeconds - 0.04));
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
            PreviewStatus = $"Preview unavailable: {FirstLine(exception.Message)}";
        }
    }
}
