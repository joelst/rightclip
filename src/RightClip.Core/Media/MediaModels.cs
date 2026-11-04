namespace RightClip.Core.Media;

public sealed record MediaInfo(
    string SourcePath,
    TimeSpan Duration,
    string FormatName,
    IReadOnlyDictionary<string, string> Tags,
    IReadOnlyList<MediaStream> Streams,
    IReadOnlyList<ChapterInfo> Chapters)
{
    public IEnumerable<MediaStream> AudioStreams => Streams.Where(stream => stream.CodecType == "audio");

    public IEnumerable<MediaStream> SubtitleStreams => Streams.Where(stream => stream.CodecType == "subtitle");

    public MediaStream? PrimaryVideo => Streams.FirstOrDefault(stream => stream.CodecType == "video");

    public TimeSpan PreviewDuration
    {
        get
        {
            if (PrimaryVideo?.Duration is not { } videoDuration || videoDuration <= TimeSpan.Zero)
            {
                return Duration;
            }

            long videoEndTicks;
            try
            {
                videoEndTicks = checked((PrimaryVideo.StartTime ?? TimeSpan.Zero).Ticks + videoDuration.Ticks);
            }
            catch (OverflowException)
            {
                return Duration;
            }

            return TimeSpan.FromTicks(Math.Clamp(videoEndTicks, 0, Duration.Ticks));
        }
    }

    public TimeSpan LastPreviewTime
    {
        get
        {
            var rate = PrimaryVideo?.FramesPerSecond is { } value && double.IsFinite(value) && value > 0 ? value : 25;
            var margin = Math.Min(PreviewDuration.TotalSeconds, Math.Max(0.001, 1 / rate));
            return TimeSpan.FromSeconds(Math.Max(0, PreviewDuration.TotalSeconds - margin));
        }
    }
}

public sealed record MediaStream(
    int Index,
    int Ordinal,
    string CodecType,
    string CodecName,
    string? Language,
    string? Title,
    int? Width,
    int? Height,
    int? Rotation,
    long? BitRate = null,
    TimeSpan? Duration = null,
    double? FramesPerSecond = null,
    TimeSpan? StartTime = null)
{
    public string DisplayName
    {
        get
        {
            var kind = CodecType == "audio" ? "Audio track" : CodecType == "subtitle" ? "Subtitle" : CodecType;
            var language = string.IsNullOrWhiteSpace(Language) ? string.Empty : $" · {Language}";
            var title = string.IsNullOrWhiteSpace(Title) ? string.Empty : $" · {Title}";
            return $"{kind} {Ordinal + 1} · {CodecName}{language}{title}";
        }
    }
}

public sealed record ChapterInfo(TimeSpan Start, TimeSpan End, string Title);

public sealed record FileOperationResult(
    string SourcePath,
    bool Succeeded,
    IReadOnlyList<string> OutputPaths,
    string? Error = null,
    bool Cancelled = false);

public sealed record OperationProgress(string SourcePath, string Status, double? Fraction = null);

public static class SupportedMedia
{
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".mov", ".mkv", ".webm"
    };

    public static bool IsSupported(string path) => Extensions.Contains(Path.GetExtension(path));

    public static string NormalizeSource(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("A video path is required.", nameof(path));
        }

        var fullPath = Path.GetFullPath(path);
        if (!IsSupported(fullPath))
        {
            throw new NotSupportedException($"{Path.GetFileName(fullPath)} is not an MP4, MOV, MKV, or WebM file.");
        }

        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException("The video file was not found.", fullPath);
        }

        return fullPath;
    }
}
