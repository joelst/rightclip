using RightClip.Core.Media;
using RightClip.Core.Operations;
using RightClip.Core.Processes;
using Xunit;

namespace RightClip.Tests;

public sealed class TrimPlanningTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public async Task ReviewsPreviousKeyframeAndAdjustedDuration()
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var source = _directory.File("clip.mp4");
        var media = Fixture.Media(source);
        var plans = await services.Trim.CreatePlansAsync([media],
            new TrimRequest(TrimMode.Start, TimeSpan.FromSeconds(3.5), StartKind: TimeInputKind.ClockTime, Encoding: CutEncoding.FastCopy),
            new OutputAllocator());
        var plan = Assert.Single(plans);
        Assert.Equal(TimeSpan.FromSeconds(3.5), plan.RequestedStart);
        Assert.Equal(TimeSpan.FromSeconds(2), plan.LandedStart);
        Assert.Equal(TimeSpan.FromSeconds(8), plan.OutputDuration);

        await services.Trim.RunAsync(plans, null);
        var request = runner.Requests.Last();
        Assert.Equal("-y", request.Arguments[2]);
        Assert.Contains("-c", request.Arguments);
        Assert.Contains("copy", request.Arguments);
        Assert.DoesNotContain(request.Arguments, argument => argument.Contains("libx264", StringComparison.OrdinalIgnoreCase));
        var keyframeArguments = VideoEncoding.GetKeyframeArguments(media);
        Assert.Contains("-force_key_frames:v:0", keyframeArguments);
        Assert.DoesNotContain("-force_key_frames", keyframeArguments);
    }

    [Fact]
    public void EndOffsetIsCalculatedPerFile()
    {
        var media = Fixture.Media(_directory.File("clip.mp4"), 12);
        var range = TrimService.ResolveRange(media, new TrimRequest(TrimMode.End, TimeSpan.Zero, TimeSpan.FromSeconds(2)));
        Assert.Equal(TimeSpan.Zero, range.Start);
        Assert.Equal(TimeSpan.FromSeconds(10), range.End);
    }

    [Fact]
    public async Task ClockTimeMustFitEveryBatchItem()
    {
        var services = Fixture.Services(_directory, new RecordingRunner());
        var first = Fixture.Media(_directory.File("short.mp4"), 4);
        var second = Fixture.Media(_directory.File("long.mp4"), 8);
        await Assert.ThrowsAsync<InvalidOperationException>(() => services.Trim.CreatePlansAsync([first, second],
            new TrimRequest(TrimMode.Start, TimeSpan.FromSeconds(5), StartKind: TimeInputKind.ClockTime), new OutputAllocator()));
        Assert.Empty(Directory.GetFiles(_directory.Path, "*.trimmed*"));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class BatchTests
{
    [Fact]
    public async Task FailureDoesNotStopRemainingFiles()
    {
        var results = await BatchRunner.RunAsync(["bad.mp4", "good.mp4"], path => path,
            async (path, token) =>
            {
                await Task.Yield();
                if (path == "bad.mp4")
                {
                    throw new InvalidOperationException("bad input");
                }

                return (IReadOnlyList<string>)["good.output.mp4"];
            }, null, CancellationToken.None);
        Assert.Equal(2, results.Count);
        Assert.False(results[0].Succeeded);
        Assert.True(results[1].Succeeded);
    }
}

public sealed class BatchConcurrencyTests
{
    [Fact]
    public async Task LimitsConcurrencyAndPreservesOrderedResults()
    {
        var active = 0;
        var maximum = 0;
        var sync = new object();
        var results = await BatchRunner.RunAsync([1, 2, 3, 4], item => item.ToString(),
            async (item, token) =>
            {
                var current = Interlocked.Increment(ref active);
                lock (sync)
                {
                    maximum = Math.Max(maximum, current);
                }

                try
                {
                    await Task.Delay(25, token);
                    if (item == 2)
                    {
                        throw new InvalidOperationException("Expected failure");
                    }

                    return (IReadOnlyList<string>)[item.ToString()];
                }
                finally
                {
                    Interlocked.Decrement(ref active);
                }
            }, null, CancellationToken.None, 2);

        Assert.True(maximum <= 2);
        Assert.Equal(new[] { "1", "2", "3", "4" }, results.Select(result => result.SourcePath));
        Assert.False(results[1].Succeeded);
        Assert.True(results[0].Succeeded && results[2].Succeeded && results[3].Succeeded);
    }
}

public sealed class KeyframeTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public async Task UsesBoundedProbeWindowWhenRequestedTimeIsAvailable()
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var source = _directory.File("clip.mp4");
        await services.Probe.GetKeyframesAsync(source, TimeSpan.FromMinutes(3));
        Assert.Contains(runner.Requests, request => request.Arguments.Contains("-read_intervals"));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class TrackTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public async Task DropsRenamesAndAddsSoftSubtitles()
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var source = _directory.File("clip.mp4");
        var subtitles = _directory.File("added.srt", "1\n00:00:00,000 --> 00:00:01,000\nHello\n");
        var request = new TrackRequest([
            new TrackSelection("audio", 0, false),
            new TrackSelection("audio", 1, true, "Music"),
            new TrackSelection("subtitle", 0, false)
        ], [new SubtitleInput(subtitles, "English", "eng")]);
        var plan = Assert.Single(services.Tracks.CreatePlans([Fixture.Media(source, secondAudio: true, subtitle: true)], request, new OutputAllocator()));
        await services.Tracks.RunAsync([plan], request, null);
        var arguments = runner.Requests.Last().Arguments;
        Assert.Contains("0:2", arguments);
        Assert.DoesNotContain("0:1", arguments);
        Assert.DoesNotContain("0:3", arguments);
        Assert.Contains("title=Music", arguments);
        Assert.Contains("1:s:0", arguments);
        var argumentList = arguments.ToList();
        Assert.True(argumentList.IndexOf("-c:s:0") > argumentList.IndexOf("-c"));
        Assert.Contains("mov_text", arguments);
    }

    [Fact]
    public void ExtractionUsesNewSubtitleSibling()
    {
        var services = Fixture.Services(_directory, new RecordingRunner());
        var source = _directory.File("clip.mkv");
        var request = new TrackRequest([new TrackSelection("subtitle", 0, true)], [], true);
        var plan = Assert.Single(services.Tracks.CreatePlans([Fixture.Media(source, subtitle: true)], request, new OutputAllocator()));
        Assert.Null(plan.OutputPath);
        Assert.EndsWith(".subtitle01.srt", plan.Extractions.Single().OutputPath);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedExtractionRemovesEarlierOutputs(bool cancel)
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var media = Fixture.Media(_directory.File("clip.mkv"), subtitle: true);
        var first = _directory.File("first.srt");
        var second = _directory.File("second.srt");
        File.Delete(first);
        File.Delete(second);
        var plan = new TrackFilePlan(media, null,
            [new SubtitleExtractionPlan(media, media.SubtitleStreams.Single(), first),
             new SubtitleExtractionPlan(media, media.SubtitleStreams.Single(), second)]);
        var writes = 0;
        runner.Handler = request =>
        {
            if (request.Arguments.Contains("-version"))
            {
                return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
            }

            File.WriteAllText(request.Arguments[^1], "partial output");
            if (++writes == 2)
            {
                if (cancel)
                {
                    throw new OperationCanceledException();
                }

                return new ProcessResult(1, string.Empty, "extraction failed", []);
            }

            return new ProcessResult(0, string.Empty, string.Empty, []);
        };

        var result = Assert.Single(await services.Tracks.RunAsync([plan], new TrackRequest([], [], true), null));
        Assert.False(result.Succeeded);
        Assert.Empty(Directory.GetFiles(_directory.Path, "*.srt"));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class DetailsTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public void EscapesMetadataAndOmitsLocation()
    {
        var request = new DetailsRequest(new Dictionary<string, string>
        {
            ["title"] = "A=B;#C",
            ["location"] = "somewhere"
        }, [new ChapterInfo(TimeSpan.Zero, TimeSpan.FromSeconds(2), "Start")], 90, true, true);
        var metadata = DetailsService.BuildMetadata(request);
        Assert.Contains("title=A\\=B\\;\\#C", metadata);
        Assert.DoesNotContain("somewhere", metadata);
        Assert.Contains("TIMEBASE=1/1000", metadata);
        Assert.Contains("title=Start", metadata);
    }

    [Fact]
    public void FastStartRejectsNonMp4ContainersCaseInsensitively()
    {
        var services = Fixture.Services(_directory, new RecordingRunner());
        var mp4 = Fixture.Media(_directory.File("clip.MP4"));
        var mkv = Fixture.Media(_directory.File("clip.mkv"));
        var request = new DetailsRequest(new Dictionary<string, string>(), [], null, true, false);
        Assert.Single(services.Details.CreatePlans([mp4], request, new OutputAllocator()));
        Assert.Throws<InvalidOperationException>(() => services.Details.CreatePlans([mkv], request, new OutputAllocator()));
    }

    [Fact]
    public async Task DirectMetadataRemovalIsolatesProbeFailuresAndPreservesExistingOutputs()
    {
        var broken = _directory.File("broken.mp4");
        var source = _directory.File("source.mp4");
        var existing = _directory.File("source-without-metadata.mp4", "existing output");
        var runner = new RecordingRunner
        {
            Handler = request =>
            {
                if (request.Arguments.Contains("-version"))
                {
                    return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
                }
                if (request.Arguments.Contains("-show_format"))
                {
                    return request.Arguments[^1] == broken
                        ? new ProcessResult(1, string.Empty, "Unreadable video", [])
                        : new ProcessResult(0, """
                            { "format": { "duration": "4", "format_name": "mp4" },
                              "streams": [{ "index": 0, "codec_type": "video", "codec_name": "mpeg4" }] }
                            """, string.Empty, []);
                }

                return new ProcessResult(0, string.Empty, string.Empty, []);
            }
        };
        var services = Fixture.Services(_directory, runner);
        var results = await services.RemoveMetadataAsync([broken, source], null);
        Assert.False(results[0].Succeeded);
        Assert.Contains("Unreadable video", results[0].Error);
        Assert.True(results[1].Succeeded, results[1].Error);
        Assert.EndsWith("source-without-metadata (2).mp4", Assert.Single(results[1].OutputPaths));
        Assert.Equal("existing output", File.ReadAllText(existing));
        Assert.Equal("fixture", File.ReadAllText(source));
        Assert.DoesNotContain(runner.Requests, request => request.BinaryStandardOutput);
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class SceneTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public async Task CreatesThumbnailReviewBeforeWriting()
    {
        var runner = new RecordingRunner();
        runner.Handler = request =>
        {
            if (request.Arguments.Contains("-version"))
            {
                return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
            }

            if (request.BinaryStandardOutput)
            {
                return new ProcessResult(0, string.Empty, string.Empty, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
            }

            if (request.StandardErrorLine is not null)
            {
                request.StandardErrorLine("frame=0 pts:123 pts_time:2.000000");
                request.StandardErrorLine("frame=1 pts:456 pts_time:4.500000");
                return new ProcessResult(0, string.Empty, "scene output", []);
            }

            if (request.Arguments.Contains("-show_frames"))
            {
                return new ProcessResult(0, "{\"frames\":[{\"pts_time\":\"0\"},{\"pts_time\":\"2\"},{\"pts_time\":\"4\"}]}", string.Empty, []);
            }

            return new ProcessResult(0, string.Empty, string.Empty, []);
        };
        var services = Fixture.Services(_directory, runner);
        var media = Fixture.Media(_directory.File("scenes.mp4"), 6);
        var plan = Assert.Single(await services.Scenes.CreatePlansAsync([media], 80, new OutputAllocator()));
        Assert.Equal(3, plan.Clips.Count);
        Assert.All(plan.Clips, clip => Assert.Equal(8, clip.Thumbnail.Length));
        Assert.Equal(TimeSpan.FromSeconds(2), plan.Clips[1].LandedStart);
        Assert.DoesNotContain(runner.Requests, request => request.Arguments.Any(argument => argument.Contains(".scene01", StringComparison.OrdinalIgnoreCase)));
        Assert.Equal(0.2, SceneService.ThresholdFromSensitivity(80), 5);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedSceneRemovesEarlierOutputs(bool cancel)
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var source = _directory.File("scenes.mp4");
        var media = Fixture.Media(source, 6);
        var first = Path.Combine(_directory.Path, "scenes.scene01.mp4");
        var second = Path.Combine(_directory.Path, "scenes.scene02.mp4");
        var plan = new SceneFilePlan(media,
            [new SceneClipPlan(1, TimeSpan.Zero, TimeSpan.Zero, TimeSpan.FromSeconds(3), [], first),
             new SceneClipPlan(2, TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(6), [], second)]);
        var writes = 0;
        runner.Handler = request =>
        {
            if (request.Arguments.Contains("-version"))
            {
                return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
            }

            File.WriteAllText(request.Arguments[^1], "partial output");
            if (++writes == 2)
            {
                if (cancel)
                {
                    throw new OperationCanceledException();
                }

                return new ProcessResult(1, string.Empty, "scene failed", []);
            }

            return new ProcessResult(0, string.Empty, string.Empty, []);
        };

        var result = Assert.Single(await services.Scenes.RunAsync([plan], null));
        Assert.False(result.Succeeded);
        Assert.Equal("fixture", File.ReadAllText(source));
        Assert.Equal(new[] { source }, Directory.GetFiles(_directory.Path, "*.mp4"));
    }

    public void Dispose() => _directory.Dispose();
}

public sealed class OutputSafetyTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OutputCreatedAfterReviewIsNeverDeleted(bool createdDuringWrite)
    {
        var runner = new RecordingRunner();
        var services = Fixture.Services(_directory, runner);
        var media = Fixture.Media(_directory.File("source.mp4"));
        var plan = Assert.Single(await services.Trim.CreatePlansAsync([media],
            new TrimRequest(TrimMode.Start, TimeSpan.FromSeconds(1)), new OutputAllocator()));
        if (!createdDuringWrite)
        {
            File.WriteAllText(plan.OutputPath, "unrelated file");
        }

        runner.Handler = request =>
        {
            if (request.Arguments.Contains("-version"))
            {
                return new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, []);
            }

            if (createdDuringWrite)
            {
                File.WriteAllText(plan.OutputPath, "unrelated file");
            }

            return new ProcessResult(0, string.Empty, string.Empty, []);
        };

        var result = Assert.Single(await services.Trim.RunAsync([plan], null));
        Assert.False(result.Succeeded);
        Assert.Equal("unrelated file", File.ReadAllText(plan.OutputPath));
        Assert.Equal("fixture", File.ReadAllText(media.SourcePath));
        Assert.Empty(Directory.GetFiles(_directory.Path, "*.partial-*"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task OutputPermissionDenialHasActionableGuidanceWithoutMislabelingInputErrors(bool outputDenied)
    {
        var source = _directory.File("source.mp4");
        var output = Path.Combine(_directory.Path, "source.new.mp4");
        var runner = new RecordingRunner
        {
            Handler = request => request.Arguments.Contains("-version")
                ? new ProcessResult(0, RecordingRunner.VersionOutput, string.Empty, [])
                : new ProcessResult(1, string.Empty, outputDenied
                    ? "Error opening output files: Permission denied."
                    : "Error opening input files: Permission denied.", [])
        };
        var services = Fixture.Services(_directory, runner);
        var failure = await Assert.ThrowsAnyAsync<Exception>(() =>
            services.Executor.RunOutputAsync(["-i", source, "-c", "copy", output]));
        if (outputDenied)
        {
            Assert.IsType<OutputAccessDeniedException>(failure);
            Assert.Contains("Controlled folder access", failure.Message);
            Assert.Contains(output, failure.Message);
        }
        else
        {
            Assert.IsType<InvalidOperationException>(failure);
            Assert.DoesNotContain("Controlled folder access", failure.Message);
        }
        Assert.Equal("fixture", File.ReadAllText(source));
        Assert.False(File.Exists(output));
        Assert.Empty(Directory.GetFiles(_directory.Path, "*.partial-*"));
    }

    public void Dispose() => _directory.Dispose();
}
