using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed class PreviewService
{
    private readonly FFmpegExecutor _ffmpeg;

    public PreviewService(FFmpegExecutor ffmpeg)
    {
        _ffmpeg = ffmpeg;
    }

    public async Task<byte[]> ReadFrameAsync(string sourcePath, TimeSpan timestamp, CancellationToken cancellationToken = default)
    {
        var bounded = timestamp < TimeSpan.Zero ? TimeSpan.Zero : timestamp;
        var bytes = await _ffmpeg.ReadBinaryAsync(["-ss", MediaTime.FFmpeg(bounded), "-i", sourcePath,
            "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=640:-2", "-c:v", "png",
            "-f", "image2pipe", "pipe:1"], cancellationToken).ConfigureAwait(false);
        if (bytes.Length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4e || bytes[3] != 0x47)
        {
            throw new InvalidOperationException("FFmpeg did not create a valid preview frame.");
        }

        return bytes;
    }
}
