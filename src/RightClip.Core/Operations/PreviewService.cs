using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed class PreviewService
{
    public const int ThumbnailCount = 12;
    public const int ThumbnailWidth = 160;
    public const int ThumbnailHeight = 90;
    private readonly FFmpegExecutor _ffmpeg;

    public PreviewService(FFmpegExecutor ffmpeg)
    {
        _ffmpeg = ffmpeg;
    }

    public async Task<byte[]> ReadFrameAsync(string sourcePath, TimeSpan timestamp, CancellationToken cancellationToken = default)
    {
        var bounded = timestamp < TimeSpan.Zero ? TimeSpan.Zero : timestamp;
        var bytes = await _ffmpeg.ReadBinaryAsync(["-loglevel", "error", "-ss", MediaTime.FFmpeg(bounded), "-i", sourcePath,
            "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=640:360:force_original_aspect_ratio=decrease", "-c:v", "png",
            "-f", "image2pipe", "pipe:1"], cancellationToken).ConfigureAwait(false);
        if (bytes.Length == 0)
        {
            var start = TimeSpan.FromSeconds(Math.Max(0, bounded.TotalSeconds - 2));
            bytes = await _ffmpeg.ReadBinaryAsync(["-loglevel", "error", "-ss", MediaTime.FFmpeg(start), "-t", "2.1",
                "-i", sourcePath, "-map", "0:v:0", "-vf", "scale=640:360:force_original_aspect_ratio=decrease,reverse", "-frames:v", "1",
                "-c:v", "png", "-f", "image2pipe", "pipe:1"], cancellationToken).ConfigureAwait(false);
        }

        ValidateFrame(bytes);
        return bytes;
    }

    public async Task<byte[]> ReadTimelineAsync(MediaInfo media, CancellationToken cancellationToken = default)
    {
        if (media.PrimaryVideo is null || media.PreviewDuration <= TimeSpan.Zero)
        {
            throw new InvalidOperationException("The video has no readable video track for timeline previews.");
        }

        var arguments = new List<string> { "-loglevel", "error", "-filter_complex_threads", "1" };
        var filters = new List<string>();
        for (var index = 0; index < ThumbnailCount; index++)
        {
            var timestamp = TimeSpan.FromTicks(Math.Min(
                media.Duration.Ticks / ThumbnailCount * index, media.LastPreviewTime.Ticks));
            arguments.AddRange(["-threads", "1", "-skip_frame", "nokey", "-noaccurate_seek",
                "-ss", MediaTime.FFmpeg(timestamp), "-i", media.SourcePath]);
            filters.Add($"[{index}:v:0]scale={ThumbnailWidth}:{ThumbnailHeight}:force_original_aspect_ratio=decrease," +
                $"pad={ThumbnailWidth}:{ThumbnailHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,trim=end_frame=1[thumb{index}]");
        }

        var inputs = string.Concat(Enumerable.Range(0, ThumbnailCount).Select(index => $"[thumb{index}]"));
        filters.Add($"{inputs}hstack=inputs={ThumbnailCount}:shortest=1[timeline]");
        arguments.AddRange(["-filter_complex", string.Join(';', filters), "-map", "[timeline]", "-frames:v", "1",
            "-c:v", "png", "-f", "image2pipe", "pipe:1"]);
        var bytes = await _ffmpeg.ReadBinaryAsync(arguments, cancellationToken).ConfigureAwait(false);
        ValidateFrame(bytes);
        return bytes;
    }

    private static void ValidateFrame(byte[] bytes)
    {
        if (bytes.Length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4e || bytes[3] != 0x47)
        {
            throw new InvalidOperationException("FFmpeg did not create a valid preview frame.");
        }
    }
}
