using RightClip.Core;
using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Tests;

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(AppContext.BaseDirectory, "work", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string File(string name, string contents = "fixture")
    {
        var path = System.IO.Path.Combine(Path, name);
        System.IO.File.WriteAllText(path, contents);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

internal sealed class RecordingRunner : IProcessRunner
{
    public List<ProcessRequest> Requests { get; } = [];

    public Func<ProcessRequest, ProcessResult>? Handler { get; set; }

    public Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        if (Handler is not null)
        {
            var result = Handler(request);
            WriteOutput(request, result);
            return Task.FromResult(result);
        }

        if (request.Arguments.Contains("-version"))
        {
            return Task.FromResult(new ProcessResult(0, VersionOutput, string.Empty, []));
        }

        if (request.Arguments.Contains("-show_frames"))
        {
            return Task.FromResult(new ProcessResult(0,
                "{\"frames\":[{\"best_effort_timestamp_time\":\"0.000000\"},{\"best_effort_timestamp_time\":\"2.000000\"},{\"best_effort_timestamp_time\":\"4.000000\"}]}", string.Empty, []));
        }

        var success = new ProcessResult(0, string.Empty, string.Empty, []);
        WriteOutput(request, success);
        return Task.FromResult(success);
    }

    private static void WriteOutput(ProcessRequest request, ProcessResult result)
    {
        if (result.ExitCode == 0 && request.Arguments.Count > 0 &&
            Path.IsPathRooted(request.Arguments[^1]) && request.Arguments[^1].Contains(".partial-", StringComparison.Ordinal))
        {
            File.WriteAllText(request.Arguments[^1], "completed output");
        }
    }

    public const string VersionOutput = "ffmpeg version n9.0-test\nconfiguration: --enable-static --disable-shared --disable-gpl --disable-nonfree\n";
}

internal static class Fixture
{
    public static MediaInfo Media(string path, double duration = 10, bool secondAudio = false, bool subtitle = false)
    {
        var streams = new List<MediaStream>
        {
            new(0, 0, "video", "mpeg4", null, null, 320, 240, 0),
            new(1, 0, "audio", "aac", "eng", "Original", null, null, null)
        };
        if (secondAudio)
        {
            streams.Add(new MediaStream(2, 1, "audio", "aac", "eng", "Music", null, null, null));
        }

        if (subtitle)
        {
            streams.Add(new MediaStream(secondAudio ? 3 : 2, 0, "subtitle", "subrip", "eng", "Existing", null, null, null));
        }

        return new MediaInfo(path, TimeSpan.FromSeconds(duration), "mov,mp4,m4a,3gp,3g2,mj2",
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["title"] = "Source" }, streams, []);
    }

    public static RightClipServices Services(TemporaryDirectory directory, RecordingRunner runner)
    {
        directory.File("ffmpeg.exe");
        directory.File("ffprobe.exe");
        return new RightClipServices(directory.Path, runner, directory.Path, false);
    }
}
