using RightClip.Core.Media;
using RightClip.Core.Operations;
using RightClip.Core.Processes;

namespace RightClip.Core;

public sealed class RightClipServices
{
    public RightClipServices(string? configuredFFmpegDirectory = null, IProcessRunner? runner = null, string? applicationDirectory = null, bool? allowDevelopmentBuild = null)
    {
        Runner = runner ?? new ProcessRunner();
        var environment = new FFmpegEnvironment(new FFmpegToolLocator(
            applicationDirectory ?? AppContext.BaseDirectory, configuredFFmpegDirectory), Runner, allowDevelopmentBuild);
        Probe = new MediaProbe(environment, Runner);
        Executor = new FFmpegExecutor(environment, Runner);
        Trim = new TrimService(Probe, Executor);
        Scenes = new SceneService(Probe, Executor);
        Tracks = new TrackService(Executor);
        Details = new DetailsService(Executor);
        Preview = new PreviewService(Executor);
    }

    public IProcessRunner Runner { get; }

    public MediaProbe Probe { get; }

    public FFmpegExecutor Executor { get; }

    public TrimService Trim { get; }

    public SceneService Scenes { get; }

    public TrackService Tracks { get; }

    public DetailsService Details { get; }

    public PreviewService Preview { get; }

    public Task<IReadOnlyList<FileOperationResult>> RemoveMetadataAsync(
        IReadOnlyList<string> sourcePaths, IProgress<OperationProgress>? progress, CancellationToken cancellationToken = default)
    {
        if (sourcePaths.Count == 0)
        {
            throw new InvalidOperationException("No video was selected.");
        }

        var outputs = new OutputAllocator();
        return BatchRunner.RunAsync(sourcePaths, path => path, async (path, token) =>
        {
            progress?.Report(new OperationProgress(path, "Reading video"));
            var media = await Probe.ProbeAsync(path, token).ConfigureAwait(false);
            return await Details.RemoveMetadataAsync(media, outputs.Allocate(media.SourcePath, "-without-metadata"),
                progress, token).ConfigureAwait(false);
        }, progress, cancellationToken);
    }
}
