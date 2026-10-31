namespace RightClip.Core.Processes;

public sealed record FFmpegToolPaths(string FFmpeg, string FFprobe);

public sealed class FFmpegToolLocator
{
    private readonly string _applicationDirectory;
    private readonly string? _configuredDirectory;
    private readonly string? _path;

    public FFmpegToolLocator(string applicationDirectory, string? configuredDirectory = null, string? path = null)
    {
        _applicationDirectory = applicationDirectory;
        _configuredDirectory = string.IsNullOrWhiteSpace(configuredDirectory) ? null : configuredDirectory;
        _path = path;
    }

    public string Resolve(string toolName)
    {
        if (toolName is not ("ffmpeg" or "ffprobe"))
        {
            throw new ArgumentException("Only ffmpeg and ffprobe can be resolved.", nameof(toolName));
        }

        var fileName = $"{toolName}.exe";
        foreach (var directory in CandidateDirectories())
        {
            if (string.IsNullOrWhiteSpace(directory))
            {
                continue;
            }

            try
            {
                var candidate = Path.Combine(directory, fileName);
                if (File.Exists(candidate))
                {
                    return Path.GetFullPath(candidate);
                }
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
            }
        }

        throw new FileNotFoundException($"Could not find {fileName}. Place it next to RightClip, choose an FFmpeg folder in Settings, or add it to PATH.");
    }

    private IEnumerable<string> CandidateDirectories()
    {
        yield return _applicationDirectory;
        if (_configuredDirectory is not null)
        {
            yield return _configuredDirectory;
        }

        var path = _path ?? Environment.GetEnvironmentVariable("PATH");
        if (path is null)
        {
            yield break;
        }

        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            yield return directory.Trim('"');
        }
    }
}

public static class FFmpegLicensePolicy
{
    public static void ValidateVersion(string versionOutput, bool requireStatic = true)
    {
        if (!versionOutput.Contains("ffmpeg version", StringComparison.OrdinalIgnoreCase) ||
            !versionOutput.Contains("configuration:", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("FFmpeg did not return a recognizable version and configuration.");
        }

        var prohibited = new[] { "--enable-gpl", "--enable-nonfree", "--enable-libx264", "--enable-libx265" };
        var enabled = prohibited.FirstOrDefault(flag => versionOutput.Contains(flag, StringComparison.OrdinalIgnoreCase));
        if (enabled is not null)
        {
            throw new InvalidOperationException($"This FFmpeg build enables {enabled}. RightClip requires a static LGPL build without GPL or nonfree components.");
        }

        if (requireStatic &&
            (versionOutput.Contains("--enable-shared", StringComparison.OrdinalIgnoreCase) ||
             (!versionOutput.Contains("--enable-static", StringComparison.OrdinalIgnoreCase) &&
              !versionOutput.Contains("--pkg-config-flags=--static", StringComparison.OrdinalIgnoreCase))))
        {
            throw new InvalidOperationException("RightClip requires a static FFmpeg build without shared FFmpeg libraries.");
        }
    }
}

public sealed class FFmpegEnvironment
{
    private readonly FFmpegToolLocator _locator;
    private readonly IProcessRunner _runner;
    private readonly bool _allowDevelopmentBuild;
    private FFmpegToolPaths? _paths;

    public FFmpegEnvironment(FFmpegToolLocator locator, IProcessRunner runner, bool? allowDevelopmentBuild = null)
    {
        _locator = locator;
        _runner = runner;
        _allowDevelopmentBuild = allowDevelopmentBuild ??
            string.Equals(Environment.GetEnvironmentVariable("RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG"), "1", StringComparison.Ordinal);
    }

    public async Task<FFmpegToolPaths> GetPathsAsync(CancellationToken cancellationToken = default)
    {
        if (_paths is not null)
        {
            return _paths;
        }

        var paths = new FFmpegToolPaths(_locator.Resolve("ffmpeg"), _locator.Resolve("ffprobe"));
        var version = await _runner.RunAsync(new ProcessRequest(paths.FFmpeg, ["-version"]), cancellationToken).ConfigureAwait(false);
        if (version.ExitCode != 0)
        {
            throw new InvalidOperationException($"ffmpeg -version failed: {version.StandardError.Trim()}");
        }

        if (!_allowDevelopmentBuild)
        {
            FFmpegLicensePolicy.ValidateVersion(version.StandardOutput);
        }

        _paths = paths;
        return paths;
    }
}
