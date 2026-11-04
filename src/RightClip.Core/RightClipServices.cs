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
}
