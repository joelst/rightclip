using RightClip.Core.Media;

namespace RightClip.Core.Processes;

public sealed class FFmpegExecutor
{
    private readonly FFmpegEnvironment _environment;
    private readonly IProcessRunner _runner;

    public FFmpegExecutor(FFmpegEnvironment environment, IProcessRunner runner)
    {
        _environment = environment;
        _runner = runner;
    }

    public async Task RunAsync(IEnumerable<string> arguments, CancellationToken cancellationToken = default, Action<string>? outputLine = null, Action<string>? errorLine = null, bool overwriteOutput = false)
    {
        var paths = await _environment.GetPathsAsync(cancellationToken).ConfigureAwait(false);
        var allArguments = new List<string> { "-hide_banner", "-nostdin", overwriteOutput ? "-y" : "-n" };
        allArguments.AddRange(arguments);
        var result = await _runner.RunAsync(new ProcessRequest(paths.FFmpeg, allArguments, StandardOutputLine: outputLine, StandardErrorLine: errorLine), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(ErrorMessage("FFmpeg", result));
        }
    }

    public async Task<byte[]> ReadBinaryAsync(IEnumerable<string> arguments, CancellationToken cancellationToken = default)
    {
        var paths = await _environment.GetPathsAsync(cancellationToken).ConfigureAwait(false);
        var allArguments = new List<string> { "-hide_banner", "-nostdin" };
        allArguments.AddRange(arguments);
        var result = await _runner.RunAsync(new ProcessRequest(paths.FFmpeg, allArguments, BinaryStandardOutput: true), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(ErrorMessage("FFmpeg", result));
        }

        return result.BinaryStandardOutput;
    }

    public async Task RunWithProgressAsync(IEnumerable<string> arguments, TimeSpan duration, string sourcePath, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var operationArguments = arguments.ToList();
        if (operationArguments.Count == 0)
        {
            throw new ArgumentException("An FFmpeg output is required.", nameof(arguments));
        }

        var allArguments = new List<string>();
        allArguments.AddRange(operationArguments.Take(operationArguments.Count - 1));
        allArguments.AddRange(["-progress", "pipe:1", "-nostats"]);
        allArguments.Add(operationArguments[^1]);
        await RunOutputAsync(allArguments, cancellationToken, line =>
        {
            if (progress is null || duration <= TimeSpan.Zero || !line.StartsWith("out_time_us=", StringComparison.Ordinal) ||
                !long.TryParse(line.AsSpan("out_time_us=".Length), out var microseconds))
            {
                return;
            }

            var fraction = Math.Clamp(TimeSpan.FromTicks(microseconds * 10).TotalSeconds / duration.TotalSeconds, 0, 1);
            progress.Report(new OperationProgress(sourcePath, "Writing", fraction));
        }).ConfigureAwait(false);
    }

    public async Task RunOutputAsync(IEnumerable<string> arguments, CancellationToken cancellationToken = default, Action<string>? outputLine = null)
    {
        var operationArguments = arguments.ToList();
        if (operationArguments.Count == 0)
        {
            throw new ArgumentException("An FFmpeg output is required.", nameof(arguments));
        }

        var output = Path.GetFullPath(operationArguments[^1]);
        var temporary = Path.Combine(Path.GetDirectoryName(output)!,
            $".{Path.GetFileNameWithoutExtension(output)}.partial-{Guid.NewGuid():N}{Path.GetExtension(output)}");
        operationArguments[^1] = temporary;
        var ownsTemporary = false;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using (new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
                {
                    ownsTemporary = true;
                }
            }
            catch (Exception exception) when (IsAccessDenied(exception))
            {
                throw new OutputAccessDeniedException(output, exception);
            }

            try
            {
                await RunAsync(operationArguments, cancellationToken, outputLine, overwriteOutput: true).ConfigureAwait(false);
            }
            catch (InvalidOperationException exception) when (IsOutputPermissionError(exception.Message))
            {
                throw new OutputAccessDeniedException(output, exception);
            }

            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                File.Move(temporary, output, overwrite: false);
            }
            catch (Exception exception) when (IsAccessDenied(exception))
            {
                throw new OutputAccessDeniedException(output, exception);
            }
        }
        catch (Exception exception)
        {
            if (ownsTemporary)
            {
                DeleteFailedOutputs([temporary], exception);
            }
            throw;
        }
    }

    private static bool IsAccessDenied(Exception exception) => exception is UnauthorizedAccessException ||
        exception is IOException && (exception.HResult & 0xffff) == 5;

    private static bool IsOutputPermissionError(string message) =>
        (message.Contains("Error opening output", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("Error writing", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("Could not write header", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("av_interleaved_write_frame", StringComparison.OrdinalIgnoreCase)) &&
        (message.Contains("Permission denied", StringComparison.OrdinalIgnoreCase) ||
         message.Contains("Access is denied", StringComparison.OrdinalIgnoreCase));

    internal static void DeleteFailedOutputs(IEnumerable<string> paths, Exception originalFailure)
    {
        var failures = new List<Exception>();
        foreach (var path in paths)
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                failures.Add(new IOException($"Could not remove failed output '{path}'.", exception));
            }
        }

        if (failures.Count > 0)
        {
            throw new AggregateException("The operation failed and some output files could not be removed.",
                new[] { originalFailure }.Concat(failures));
        }
    }

    private static string ErrorMessage(string tool, ProcessResult result)
    {
        var error = string.IsNullOrWhiteSpace(result.StandardError) ? result.StandardOutput : result.StandardError;
        error = error.Trim();
        if (error.Length > 6000)
        {
            error = error[^6000..];
        }

        return string.IsNullOrWhiteSpace(error) ? $"{tool} failed with exit code {result.ExitCode}." : $"{tool} failed: {error}";
    }
}
