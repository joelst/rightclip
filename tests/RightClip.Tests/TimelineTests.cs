using RightClip.Core.Operations;
using RightClip.Core.Media;
using RightClip.Core.Processes;
using Xunit;

namespace RightClip.Tests;

public sealed class TimelineTests
{
    [Fact]
    public void CutEditingPreservesCoverageAndClipSelection()
    {
        var timeline = new TrimTimeline(TimeSpan.FromSeconds(10));
        timeline.AddCut(TimeSpan.FromSeconds(3));
        timeline.AddCut(TimeSpan.FromSeconds(7));
        timeline.ToggleSegment(1);
        timeline.MoveCut(TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(4));

        Assert.Equal(new[]
        {
            new TrimSegment(TimeSpan.Zero, TimeSpan.FromSeconds(4)),
            new TrimSegment(TimeSpan.FromSeconds(4), TimeSpan.FromSeconds(7), false),
            new TrimSegment(TimeSpan.FromSeconds(7), TimeSpan.FromSeconds(10))
        }, timeline.Segments);

        timeline.AddCut(TimeSpan.FromSeconds(5));
        Assert.False(timeline.Segments[1].IsSelected);
        Assert.False(timeline.Segments[2].IsSelected);
        timeline.RemoveCut(TimeSpan.FromSeconds(4));
        Assert.False(timeline.Segments[0].IsSelected);
        Assert.Equal(TimeSpan.FromSeconds(10), TimeSpan.FromTicks(timeline.Segments.Sum(segment => segment.Duration.Ticks)));
    }

    [Fact]
    public void InvalidCutsCannotChangeTheTimeline()
    {
        var timeline = new TrimTimeline(TimeSpan.FromSeconds(10));
        timeline.AddCut(TimeSpan.FromSeconds(3));
        timeline.AddCut(TimeSpan.FromSeconds(7));
        var original = timeline.Segments;
        Assert.Throws<InvalidOperationException>(() => timeline.AddCut(TimeSpan.Zero));
        Assert.Throws<InvalidOperationException>(() => timeline.AddCut(TimeSpan.FromSeconds(3)));
        Assert.Throws<InvalidOperationException>(() => timeline.MoveCut(TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(7)));
        Assert.Throws<InvalidOperationException>(() => timeline.RemoveCut(TimeSpan.FromSeconds(10)));
        Assert.Equal(original, timeline.Segments);
    }
}

public sealed class TimelineExportTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public async Task ExportsOnlySelectedRangesWithSafeClipNames()
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var media = Fixture.Media(_directory.File("video.mp4"), 10);
        _directory.File("video.clip01.mp4", "existing clip");
        var timeline = new TrimTimeline(media.Duration);
        timeline.AddCut(TimeSpan.FromSeconds(3));
        timeline.AddCut(TimeSpan.FromSeconds(7));
        timeline.ToggleSegment(1);

        var plans = await services.Trim.CreateClipPlansAsync(media, timeline.Segments, new OutputAllocator());
        Assert.Equal(2, plans.Count);
        Assert.EndsWith("video.clip01 (2).mp4", plans[0].OutputPath);
        Assert.Equal(TimeSpan.FromSeconds(7), plans[1].LandedStart);
        Assert.All(plans, plan => Assert.Equal(CutEncoding.KeyframeSafe, plan.Encoding));
        var result = Assert.Single(await services.Trim.RunClipsAsync(plans, null));
        Assert.True(result.Succeeded, result.Error);
        Assert.Equal(2, result.OutputPaths.Count);
        Assert.Equal("fixture", File.ReadAllText(media.SourcePath));
        Assert.Equal("existing clip", File.ReadAllText(Path.Combine(_directory.Path, "video.clip01.mp4")));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedClipExportRollsBackEarlierClips(bool cancel)
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var media = Fixture.Media(_directory.File("video.mp4"), 10);
        var timeline = new TrimTimeline(media.Duration);
        timeline.AddCut(TimeSpan.FromSeconds(5));
        var plans = await services.Trim.CreateClipPlansAsync(media, timeline.Segments, new OutputAllocator());
        var writes = 0;
        runner.Handler = request =>
        {
            if (request.Arguments.Contains("-version"))
            {
                return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
            }

            File.WriteAllText(request.Arguments[^1], "partial clip");
            if (++writes == 2)
            {
                if (cancel)
                {
                    throw new OperationCanceledException();
                }

                return new ProcessResult(1, string.Empty, "clip export failed", []);
            }

            return new ProcessResult(0, string.Empty, string.Empty, []);
        };

        var result = Assert.Single(await services.Trim.RunClipsAsync(plans, null));
        Assert.False(result.Succeeded);
        Assert.Empty(result.OutputPaths);
        Assert.Equal(new[] { media.SourcePath }, Directory.GetFiles(_directory.Path, "*.mp4"));
    }

    public void Dispose() => _directory.Dispose();
}
