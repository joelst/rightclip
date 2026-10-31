using RightClip.Core.Launch;
using RightClip.Core.Media;
using RightClip.Core.Operations;
using RightClip.Core.Processes;
using Xunit;

namespace RightClip.Tests;

public sealed class MediaTimeTests
{
    [Theory]
    [InlineData("1.25", 1.25)]
    [InlineData("02:03", 123)]
    [InlineData("01:02:03.500", 3723.5)]
    [InlineData("120:00", 7200)]
    public void ParsesSupportedTimes(string input, double seconds)
    {
        Assert.Equal(TimeSpan.FromSeconds(seconds), MediaTime.Parse(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData("-1")]
    [InlineData("1:60")]
    [InlineData("1:2:60")]
    [InlineData("1e3")]
    [InlineData("tomorrow")]
    public void RejectsInvalidTimes(string input)
    {
        Assert.False(MediaTime.TryParse(input, out _));
    }

    [Fact]
    public void DisplaysTotalHours()
    {
        Assert.Equal("25:02:03.004", MediaTime.Display(TimeSpan.FromHours(25) + TimeSpan.FromMinutes(2) + TimeSpan.FromSeconds(3.004)));
    }
}

public sealed class OutputAllocatorTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public void AllocatesUniqueSiblingsWithoutCreatingThem()
    {
        var source = _directory.File("clip.mp4");
        var existing = _directory.File("clip.trimmed.mp4");
        var allocator = new OutputAllocator();
        var first = allocator.Allocate(source, ".trimmed");
        var second = allocator.Allocate(source, ".trimmed");
        Assert.Equal(Path.Combine(_directory.Path, "clip.trimmed (2).mp4"), first);
        Assert.Equal(Path.Combine(_directory.Path, "clip.trimmed (3).mp4"), second);
        Assert.False(File.Exists(first));
        Assert.Equal("fixture", File.ReadAllText(existing));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class LocatorTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public void UsesApplicationThenConfiguredThenPathOrder()
    {
        var app = Directory.CreateDirectory(Path.Combine(_directory.Path, "app")).FullName;
        var configured = Directory.CreateDirectory(Path.Combine(_directory.Path, "configured")).FullName;
        var path = Directory.CreateDirectory(Path.Combine(_directory.Path, "path")).FullName;
        foreach (var directory in new[] { app, configured, path })
        {
            File.WriteAllText(Path.Combine(directory, "ffmpeg.exe"), directory);
        }

        Assert.Equal(Path.Combine(app, "ffmpeg.exe"), new FFmpegToolLocator(app, configured, path).Resolve("ffmpeg"));
        File.Delete(Path.Combine(app, "ffmpeg.exe"));
        Assert.Equal(Path.Combine(configured, "ffmpeg.exe"), new FFmpegToolLocator(app, configured, path).Resolve("ffmpeg"));
        File.Delete(Path.Combine(configured, "ffmpeg.exe"));
        Assert.Equal(Path.Combine(path, "ffmpeg.exe"), new FFmpegToolLocator(app, configured, path).Resolve("ffmpeg"));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class LicensePolicyTests
{
    [Fact]
    public void AcceptsStaticLgplConfiguration()
    {
        FFmpegLicensePolicy.ValidateVersion(RecordingRunner.VersionOutput);
        FFmpegLicensePolicy.ValidateVersion("ffmpeg version n9.0\nconfiguration: --pkg-config-flags=--static --disable-libx264");
    }

    [Theory]
    [InlineData("--enable-gpl")]
    [InlineData("--enable-nonfree")]
    [InlineData("--enable-libx264")]
    [InlineData("--enable-libx265")]
    [InlineData("--enable-shared --pkg-config-flags=--static")]
    public void RejectsProhibitedConfiguration(string configuration)
    {
        Assert.Throws<InvalidOperationException>(() => FFmpegLicensePolicy.ValidateVersion($"ffmpeg version n9.0\nconfiguration: {configuration}"));
    }
}

public sealed class WorkerArgumentTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public void ParsesActionAndDeduplicatesPaths()
    {
        var source = _directory.File("clip.mp4");
        var result = WorkerArguments.Parse(["--action", "tracks", "--path", source, source]);
        Assert.Equal("tracks", result.Action);
        Assert.Single(result.Paths);
    }

    [Fact]
    public void RejectsUnsupportedFilesBeforeLaunchingWorker()
    {
        var source = _directory.File("notes.txt");
        Assert.Throws<NotSupportedException>(() => WorkerArguments.Parse(["--path", source]));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class ProbeParsingTests
{
    [Fact]
    public void ParsesStreamsTagsChaptersAndRotation()
    {
        var media = MediaProbe.Parse("clip.mp4", """
            {
              "streams": [
                { "index": 0, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080,
                  "side_data_list": [{ "rotation": -90 }] },
                { "index": 1, "codec_name": "aac", "codec_type": "audio", "tags": { "language": "eng", "title": "Main" } },
                { "index": 2, "codec_name": "subrip", "codec_type": "subtitle" }
              ],
              "chapters": [{ "start_time": "0.0", "end_time": "2.5", "tags": { "title": "Opening" } }],
              "format": { "format_name": "mov,mp4", "duration": "10.25", "tags": { "title": "Example" } }
            }
            """);
        Assert.Equal(TimeSpan.FromSeconds(10.25), media.Duration);
        Assert.Equal(270, media.PrimaryVideo!.Rotation);
        Assert.Equal("Main", media.AudioStreams.Single().Title);
        Assert.Equal(0, media.SubtitleStreams.Single().Ordinal);
        Assert.Equal("Opening", media.Chapters.Single().Title);
    }

    [Fact]
    public void SnapsToPreviousKeyframe()
    {
        var frames = new[] { TimeSpan.Zero, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4) };
        Assert.Equal(TimeSpan.FromSeconds(2), MediaProbe.SnapToPreviousKeyframe(TimeSpan.FromSeconds(3.9), frames));
        Assert.Equal(TimeSpan.Zero, MediaProbe.SnapToPreviousKeyframe(TimeSpan.FromSeconds(1), frames));
    }
}
