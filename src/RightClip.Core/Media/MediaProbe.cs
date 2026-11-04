using System.Globalization;
using System.Text.Json;
using RightClip.Core.Processes;

namespace RightClip.Core.Media;

public sealed class MediaProbe
{
    private readonly FFmpegEnvironment _environment;
    private readonly IProcessRunner _runner;

    public MediaProbe(FFmpegEnvironment environment, IProcessRunner runner)
    {
        _environment = environment;
        _runner = runner;
    }

    public async Task<MediaInfo> ProbeAsync(string sourcePath, CancellationToken cancellationToken = default)
    {
        sourcePath = SupportedMedia.NormalizeSource(sourcePath);
        var paths = await _environment.GetPathsAsync(cancellationToken).ConfigureAwait(false);
        var result = await _runner.RunAsync(new ProcessRequest(paths.FFprobe,
            ["-v", "error", "-show_format", "-show_streams", "-show_chapters", "-of", "json", sourcePath]), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"FFprobe could not read {Path.GetFileName(sourcePath)}: {ErrorText(result)}");
        }

        try
        {
            return Parse(sourcePath, result.StandardOutput);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or FormatException or OverflowException)
        {
            throw new InvalidOperationException($"FFprobe returned invalid media information for {Path.GetFileName(sourcePath)}: {exception.Message}", exception);
        }
    }

    public Task<IReadOnlyList<TimeSpan>> GetKeyframesAsync(string sourcePath, CancellationToken cancellationToken = default) =>
        GetKeyframesAsync(sourcePath, null, cancellationToken);

    public async Task<IReadOnlyList<TimeSpan>> GetKeyframesAsync(string sourcePath, TimeSpan? requestedTime, CancellationToken cancellationToken = default)
    {
        var paths = await _environment.GetPathsAsync(cancellationToken).ConfigureAwait(false);
        var arguments = new List<string> { "-v", "error" };
        if (requestedTime is { } requested && requested > TimeSpan.FromMinutes(2))
        {
            var start = requested - TimeSpan.FromMinutes(2);
            arguments.AddRange(["-read_intervals", $"{MediaTime.FFmpeg(start)}%{MediaTime.FFmpeg(requested + TimeSpan.FromSeconds(1))}"]);
        }

        arguments.AddRange(["-select_streams", "v:0", "-skip_frame", "nokey", "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time,pts_time", "-of", "json", sourcePath]);
        var result = await _runner.RunAsync(new ProcessRequest(paths.FFprobe, arguments), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"FFprobe could not find keyframes: {ErrorText(result)}");
        }

        using var document = JsonDocument.Parse(result.StandardOutput);
        var keyframes = new List<TimeSpan>();
        if (document.RootElement.TryGetProperty("frames", out var frames) && frames.ValueKind == JsonValueKind.Array)
        {
            foreach (var frame in frames.EnumerateArray())
            {
                if (TryReadSeconds(frame, "best_effort_timestamp_time", out var timestamp) ||
                    TryReadSeconds(frame, "pts_time", out timestamp))
                {
                    keyframes.Add(timestamp);
                }
            }
        }

        var ordered = keyframes.Where(value => value >= TimeSpan.Zero).Distinct().OrderBy(value => value).ToArray();
        if (requestedTime is { } fallbackTime && fallbackTime > TimeSpan.FromMinutes(2) &&
            (ordered.Length == 0 || ordered[0] > fallbackTime))
        {
            return await GetKeyframesAsync(sourcePath, null, cancellationToken).ConfigureAwait(false);
        }

        return ordered;
    }

    public static MediaInfo Parse(string sourcePath, string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var format = root.GetProperty("format");
        var duration = ReadSeconds(format, "duration") ?? TimeSpan.Zero;
        var tags = ReadTags(format);
        var formatName = ReadString(format, "format_name") ?? string.Empty;
        var streams = new List<MediaStream>();
        var audioOrdinal = 0;
        var subtitleOrdinal = 0;
        var videoOrdinal = 0;

        foreach (var stream in root.GetProperty("streams").EnumerateArray())
        {
            var codecType = ReadString(stream, "codec_type") ?? "unknown";
            var ordinal = codecType switch
            {
                "audio" => audioOrdinal++,
                "subtitle" => subtitleOrdinal++,
                "video" => videoOrdinal++,
                _ => 0
            };
            var streamTags = ReadTags(stream);
            var rotation = ReadRotation(stream, streamTags);
            streams.Add(new MediaStream(
                stream.GetProperty("index").GetInt32(),
                ordinal,
                codecType,
                ReadString(stream, "codec_name") ?? "unknown",
                ReadTag(streamTags, "language"),
                ReadTag(streamTags, "title"),
                ReadInt(stream, "width"),
                ReadInt(stream, "height"),
                rotation,
                ReadLong(stream, "bit_rate"),
                ReadSeconds(stream, "duration") ?? ReadDurationTag(streamTags),
                ReadFrameRate(stream),
                ReadSeconds(stream, "start_time")));
        }

        var chapters = new List<ChapterInfo>();
        if (root.TryGetProperty("chapters", out var chapterArray))
        {
            foreach (var chapter in chapterArray.EnumerateArray())
            {
                var start = ReadSeconds(chapter, "start_time") ?? TimeSpan.Zero;
                var end = ReadSeconds(chapter, "end_time") ?? start;
                var chapterTags = ReadTags(chapter);
                chapters.Add(new ChapterInfo(start, end, ReadTag(chapterTags, "title") ?? string.Empty));
            }
        }

        if (duration <= TimeSpan.Zero)
        {
            duration = chapters.Count > 0 ? chapters.Max(chapter => chapter.End) : TimeSpan.Zero;
        }

        if (duration <= TimeSpan.Zero || streams.Count == 0)
        {
            throw new InvalidOperationException("The file has no readable media duration or streams.");
        }

        return new MediaInfo(sourcePath, duration, formatName, tags, streams, chapters);
    }

    internal static TimeSpan SnapToPreviousKeyframe(TimeSpan requested, IReadOnlyList<TimeSpan> keyframes)
    {
        if (requested < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(requested));
        }

        return keyframes.Where(keyframe => keyframe <= requested).DefaultIfEmpty(TimeSpan.Zero).Max();
    }

    private static int? ReadRotation(JsonElement stream, IReadOnlyDictionary<string, string> tags)
    {
        if (stream.TryGetProperty("side_data_list", out var sideData))
        {
            foreach (var item in sideData.EnumerateArray())
            {
                if (item.TryGetProperty("rotation", out var rotation) && rotation.TryGetInt32(out var degrees))
                {
                    return ((degrees % 360) + 360) % 360;
                }
            }
        }

        if (ReadTag(tags, "rotate") is { } rotate && int.TryParse(rotate, NumberStyles.Integer, CultureInfo.InvariantCulture, out var tagDegrees))
        {
            return ((tagDegrees % 360) + 360) % 360;
        }

        return null;
    }

    private static IReadOnlyDictionary<string, string> ReadTags(JsonElement element)
    {
        var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (element.TryGetProperty("tags", out var tagElement) && tagElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var tag in tagElement.EnumerateObject())
            {
                tags[tag.Name] = tag.Value.ValueKind == JsonValueKind.String ? tag.Value.GetString() ?? string.Empty : tag.Value.ToString();
            }
        }

        return tags;
    }

    private static string? ReadTag(IReadOnlyDictionary<string, string> tags, string key) => tags.TryGetValue(key, out var value) ? value : null;

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? ReadInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : null;

    private static long? ReadLong(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
        {
            return number;
        }

        return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)
            ? number
            : null;
    }

    private static TimeSpan? ReadSeconds(JsonElement element, string name) => TryReadSeconds(element, name, out var value) ? value : null;

    private static TimeSpan? ReadDurationTag(IReadOnlyDictionary<string, string> tags) =>
        ReadTag(tags, "DURATION") is { } text && MediaTime.TryParse(text, out var duration) ? duration : null;

    private static double? ReadFrameRate(JsonElement stream)
    {
        foreach (var name in new[] { "avg_frame_rate", "r_frame_rate" })
        {
            var parts = ReadString(stream, name)?.Split('/');
            if (parts is not { Length: 2 } ||
                !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var numerator) ||
                !double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var denominator) ||
                numerator <= 0 || denominator <= 0)
            {
                continue;
            }

            var rate = numerator / denominator;
            if (double.IsFinite(rate) && rate > 0)
            {
                return rate;
            }
        }

        return null;
    }

    private static bool TryReadSeconds(JsonElement element, string name, out TimeSpan timestamp)
    {
        timestamp = default;
        if (!element.TryGetProperty(name, out var value))
        {
            return false;
        }

        var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.ValueKind == JsonValueKind.Number ? value.GetRawText() : null;
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) || !double.IsFinite(seconds))
        {
            return false;
        }

        timestamp = TimeSpan.FromSeconds(seconds);
        return true;
    }

    private static string ErrorText(ProcessResult result) => string.IsNullOrWhiteSpace(result.StandardError)
        ? $"exit code {result.ExitCode}"
        : result.StandardError.Trim();
}
