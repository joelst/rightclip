using System.Security.Cryptography;
using System.Text;
using RightClip.Core;
using RightClip.Core.Media;
using RightClip.Core.Operations;
using RightClip.Core.Processes;
using Xunit;

namespace RightClip.Tests;

public sealed class RealMediaFixture : IAsyncLifetime
{
    private readonly string? _toolDirectory = Environment.GetEnvironmentVariable("RIGHTCLIP_TEST_FFMPEG_DIR");

    public string Root { get; } = Path.Combine(AppContext.BaseDirectory, "real-media", Guid.NewGuid().ToString("N"));

    public RightClipServices Services { get; private set; } = null!;

    public string Source { get; private set; } = null!;

    public string TrackSource { get; private set; } = null!;

    public string SceneSource { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        if (string.IsNullOrWhiteSpace(_toolDirectory))
        {
            return;
        }

        Directory.CreateDirectory(Root);
        Services = new RightClipServices(_toolDirectory, applicationDirectory: _toolDirectory, allowDevelopmentBuild: false);
        Source = Path.Combine(Root, "source.mp4");
        TrackSource = Path.Combine(Root, "tracks.mkv");
        SceneSource = Path.Combine(Root, "scenes.mp4");
        var subtitles = Path.Combine(Root, "added.srt");
        await File.WriteAllTextAsync(subtitles, "1\n00:00:00,000 --> 00:00:02,000\nRightClip subtitle\n");
        var locator = new FFmpegToolLocator(_toolDirectory);
        var ffmpeg = locator.Resolve("ffmpeg");
        await Run(ffmpeg, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:v", "mpeg4", "-g", "25",
            "-c:a", "aac", "-movflags", "+faststart", Source]);
        await Run(ffmpeg, ["-i", Source, "-f", "lavfi", "-i", "sine=frequency=880:duration=4", "-i", subtitles,
            "-map", "0:v:0", "-map", "0:a:0", "-map", "1:a:0", "-map", "2:s:0", "-c:v", "copy",
            "-c:a", "aac", "-c:s", "srt", "-metadata:s:a:0", "title=English", "-metadata:s:a:1", "title=Music",
            "-metadata:s:s:0", "title=Existing", "-metadata", "title=Track fixture", TrackSource]);
        await Run(ffmpeg, ["-f", "lavfi", "-i", "color=c=red:size=320x240:rate=25:duration=2",
            "-f", "lavfi", "-i", "color=c=black:size=320x240:rate=25:duration=2",
            "-f", "lavfi", "-i", "color=c=white:size=320x240:rate=25:duration=2",
            "-filter_complex", "[0:v][1:v][2:v]concat=n=3:v=1:a=0,format=yuv420p[v]",
            "-map", "[v]", "-c:v", "mpeg4", "-g", "25", SceneSource]);
    }

    public Task DisposeAsync()
    {
        try
        {
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, true);
            }
        }
        catch (IOException)
        {
        }

        return Task.CompletedTask;
    }

    private static async Task Run(string ffmpeg, IReadOnlyList<string> arguments)
    {
        var allArguments = new List<string> { "-hide_banner", "-nostdin", "-n" };
        allArguments.AddRange(arguments);
        var result = await new ProcessRunner().RunAsync(new ProcessRequest(ffmpeg, allArguments));
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"Fixture generation failed: {result.StandardError}");
        }
    }
}

public sealed class RealMediaTests : IClassFixture<RealMediaFixture>
{
    private readonly RealMediaFixture _fixture;

    public RealMediaTests(RealMediaFixture fixture)
    {
        _fixture = fixture;
    }

    [IntegrationFact]
    public async Task TrimShowsKeyframeWritesNewSiblingAndAvoidsCollisions()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.Source);
        var originalHash = Hash(_fixture.Source);
        var request = new TrimRequest(TrimMode.Start, TimeSpan.FromSeconds(2.4), StartKind: TimeInputKind.ClockTime, Encoding: CutEncoding.FastCopy);
        var firstPlan = Assert.Single(await _fixture.Services.Trim.CreatePlansAsync([media], request, new OutputAllocator()));
        Assert.Equal(TimeSpan.FromSeconds(2), firstPlan.LandedStart);
        var firstResult = Assert.Single(await _fixture.Services.Trim.RunAsync([firstPlan], null));
        Assert.True(firstResult.Succeeded, firstResult.Error);
        var secondPlan = Assert.Single(await _fixture.Services.Trim.CreatePlansAsync([media], request, new OutputAllocator()));
        Assert.EndsWith(".trimmed (2).mp4", secondPlan.OutputPath);
        var secondResult = Assert.Single(await _fixture.Services.Trim.RunAsync([secondPlan], null));
        Assert.True(secondResult.Succeeded, secondResult.Error);
        Assert.True(File.Exists(firstPlan.OutputPath));
        Assert.True(File.Exists(secondPlan.OutputPath));
        Assert.NotEqual(firstPlan.OutputPath, secondPlan.OutputPath);
        Assert.Equal(originalHash, Hash(_fixture.Source));
        var output = await _fixture.Services.Probe.ProbeAsync(firstPlan.OutputPath);
        Assert.InRange(output.Duration.TotalSeconds, 1.8, 2.2);
    }

    [IntegrationFact]
    public async Task TrimEndAndKeepRangeUseStreamCopy()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.Source);
        var outputs = new OutputAllocator();
        var endPlan = Assert.Single(await _fixture.Services.Trim.CreatePlansAsync([media],
            new TrimRequest(TrimMode.End, TimeSpan.Zero, TimeSpan.FromSeconds(1), Encoding: CutEncoding.FastCopy), outputs));
        var rangePlan = Assert.Single(await _fixture.Services.Trim.CreatePlansAsync([media],
            new TrimRequest(TrimMode.Range, TimeSpan.FromSeconds(1.25), TimeSpan.FromSeconds(3.25), Encoding: CutEncoding.FastCopy), outputs));
        Assert.Equal(TimeSpan.FromSeconds(3), endPlan.RequestedEnd);
        Assert.Equal(TimeSpan.FromSeconds(1), rangePlan.LandedStart);
        Assert.NotEqual(endPlan.OutputPath, rangePlan.OutputPath);
        var results = await _fixture.Services.Trim.RunAsync([endPlan, rangePlan], null);
        Assert.All(results, result => Assert.True(result.Succeeded, result.Error));
        Assert.InRange((await _fixture.Services.Probe.ProbeAsync(endPlan.OutputPath)).Duration.TotalSeconds, 2.8, 3.2);
        Assert.InRange((await _fixture.Services.Probe.ProbeAsync(rangePlan.OutputPath)).Duration.TotalSeconds, 2.0, 2.5);
    }

    [IntegrationFact]
    public async Task KeyframeSafeCutUsesExactStartAndCreatesKeyframe()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.Source);
        var request = new TrimRequest(TrimMode.Range, TimeSpan.FromSeconds(1.25), TimeSpan.FromSeconds(3.25));
        var plan = Assert.Single(await _fixture.Services.Trim.CreatePlansAsync([media], request, new OutputAllocator()));
        Assert.Equal(CutEncoding.KeyframeSafe, plan.Encoding);
        Assert.Equal(TimeSpan.FromSeconds(1.25), plan.LandedStart);
        var result = Assert.Single(await _fixture.Services.Trim.RunAsync([plan], null));
        Assert.True(result.Succeeded, result.Error);
        var output = await _fixture.Services.Probe.ProbeAsync(plan.OutputPath);
        Assert.InRange(output.Duration.TotalSeconds, 1.8, 2.2);
        var keyframes = await _fixture.Services.Probe.GetKeyframesAsync(plan.OutputPath);
        Assert.NotEmpty(keyframes);
        Assert.True(keyframes[0].TotalSeconds < 0.1);
    }

    [IntegrationFact]
    public async Task FailedBatchItemLeavesTheNextFileRunning()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.Source);
        var missing = Fixture.Media(Path.Combine(_fixture.Root, "missing.mp4"), 4);
        var outputs = new OutputAllocator();
        var badPlan = new TrimFilePlan(missing, TimeSpan.Zero, TimeSpan.Zero, TimeSpan.FromSeconds(1), outputs.Allocate(missing.SourcePath, ".trimmed"));
        var goodPlan = new TrimFilePlan(media, TimeSpan.Zero, TimeSpan.Zero, TimeSpan.FromSeconds(1), outputs.Allocate(media.SourcePath, ".trimmed"));
        var results = await _fixture.Services.Trim.RunAsync([badPlan, goodPlan], null);
        Assert.False(results[0].Succeeded);
        Assert.True(results[1].Succeeded, results[1].Error);
        Assert.True(File.Exists(goodPlan.OutputPath));
    }

    [IntegrationFact]
    public async Task TracksDropsRenamesAddsAndExtractsSoftSubtitles()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.TrackSource);
        var request = new TrackRequest([
            new TrackSelection("audio", 0, true, "Main audio"),
            new TrackSelection("audio", 1, false),
            new TrackSelection("subtitle", 0, true)
        ], [new SubtitleInput(Path.Combine(_fixture.Root, "added.srt"), "Added subtitle", "eng")]);
        var plan = Assert.Single(_fixture.Services.Tracks.CreatePlans([media], request, new OutputAllocator()));
        var result = Assert.Single(await _fixture.Services.Tracks.RunAsync([plan], request, null));
        Assert.True(result.Succeeded, result.Error);
        var output = await _fixture.Services.Probe.ProbeAsync(plan.OutputPath!);
        Assert.Single(output.AudioStreams);
        Assert.Equal("Main audio", output.AudioStreams.Single().Title);
        Assert.Equal(2, output.SubtitleStreams.Count());
        Assert.Contains(output.SubtitleStreams, stream => stream.Title == "Added subtitle" && stream.Language == "eng");

        var extractRequest = new TrackRequest([new TrackSelection("subtitle", 1, true)], [], true);
        var extraction = Assert.Single(_fixture.Services.Tracks.CreatePlans([output], extractRequest, new OutputAllocator()));
        var extracted = Assert.Single(await _fixture.Services.Tracks.RunAsync([extraction], extractRequest, null));
        Assert.True(extracted.Succeeded, extracted.Error);
        Assert.Contains("RightClip subtitle", await File.ReadAllTextAsync(extraction.Extractions.Single().OutputPath));
    }

    [IntegrationFact]
    public async Task DetailsEditsTagsChaptersRotationFastStartAndLocation()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.Source);
        var tags = new Dictionary<string, string>(media.Tags, StringComparer.OrdinalIgnoreCase)
        {
            ["title"] = "Edited = title",
            ["artist"] = "RightClip",
            ["location"] = "+47.1000-122.1000/"
        };
        var request = new DetailsRequest(tags, [
            new ChapterInfo(TimeSpan.Zero, TimeSpan.FromSeconds(1.5), "Opening"),
            new ChapterInfo(TimeSpan.FromSeconds(1.5), TimeSpan.FromSeconds(3.5), "Ending")
        ], 90, true, true);
        var originalHash = Hash(_fixture.Source);
        var plan = Assert.Single(_fixture.Services.Details.CreatePlans([media], request, new OutputAllocator()));
        var result = Assert.Single(await _fixture.Services.Details.RunAsync([plan], request, null));
        Assert.True(result.Succeeded, result.Error);
        var output = await _fixture.Services.Probe.ProbeAsync(plan.OutputPath);
        Assert.Equal("Edited = title", output.Tags["title"]);
        Assert.Equal("RightClip", output.Tags["artist"]);
        Assert.False(output.Tags.ContainsKey("location"));
        Assert.Equal(2, output.Chapters.Count);
        Assert.Equal("Opening", output.Chapters[0].Title);
        Assert.Equal(90, output.PrimaryVideo!.Rotation);
        var bytes = await File.ReadAllBytesAsync(plan.OutputPath);
        Assert.InRange(IndexOf(bytes, "moov"u8.ToArray()), 0, IndexOf(bytes, "mdat"u8.ToArray()) - 1);
        Assert.Equal(originalHash, Hash(_fixture.Source));
    }

    [IntegrationFact]
    public async Task SceneReviewHasThumbnailsAndClipCountBeforeSplitting()
    {
        var media = await _fixture.Services.Probe.ProbeAsync(_fixture.SceneSource);
        var plan = Assert.Single(await _fixture.Services.Scenes.CreatePlansAsync([media], 80, new OutputAllocator()));
        Assert.Equal(3, plan.Clips.Count);
        Assert.All(plan.Clips, clip => Assert.True(clip.Thumbnail.Length > 8));
        Assert.Equal(TimeSpan.FromSeconds(2), plan.Clips[1].RequestedStart);
        Assert.Equal(TimeSpan.FromSeconds(4), plan.Clips[2].RequestedStart);
        Assert.False(File.Exists(plan.Clips[0].OutputPath));
        var result = Assert.Single(await _fixture.Services.Scenes.RunAsync([plan], null));
        Assert.True(result.Succeeded, result.Error);
        Assert.Equal(3, result.OutputPaths.Count);
        Assert.All(plan.Clips, clip => Assert.True(File.Exists(clip.OutputPath)));
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static int IndexOf(byte[] data, byte[] pattern)
    {
        for (var index = 0; index <= data.Length - pattern.Length; index++)
        {
            if (data.AsSpan(index, pattern.Length).SequenceEqual(pattern))
            {
                return index;
            }
        }

        return -1;
    }
}
