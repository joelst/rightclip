using Xunit;

namespace RightClip.Tests;

public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute()
    {
        var directory = Environment.GetEnvironmentVariable("RIGHTCLIP_TEST_FFMPEG_DIR");
        if (string.IsNullOrWhiteSpace(directory) ||
            !File.Exists(Path.Combine(directory, "ffmpeg.exe")) ||
            !File.Exists(Path.Combine(directory, "ffprobe.exe")))
        {
            Skip = "Set RIGHTCLIP_TEST_FFMPEG_DIR to a static LGPL FFmpeg tool directory to run real-media integration tests.";
        }
    }
}
