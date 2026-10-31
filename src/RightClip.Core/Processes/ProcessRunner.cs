using System.Diagnostics;
using System.Text;

namespace RightClip.Core.Processes;

public sealed record ProcessRequest(
    string Executable,
    IReadOnlyList<string> Arguments,
    bool BinaryStandardOutput = false,
    Action<string>? StandardOutputLine = null,
    Action<string>? StandardErrorLine = null);

public sealed record ProcessResult(
    int ExitCode,
    string StandardOutput,
    string StandardError,
    byte[] BinaryStandardOutput);

public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken = default);
}

public sealed class ProcessRunner : IProcessRunner
{
    public async Task<ProcessResult> RunAsync(ProcessRequest request, CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = request.Executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in request.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException($"Could not start {Path.GetFileName(request.Executable)}.");
            }
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new InvalidOperationException($"Could not start {Path.GetFileName(request.Executable)}: {exception.Message}", exception);
        }

        var stdoutTask = request.BinaryStandardOutput
            ? ReadBinaryAsync(process.StandardOutput.BaseStream)
            : ReadTextAsync(process.StandardOutput, request.StandardOutputLine);
        var stderrTask = ReadTextAsync(process.StandardError, request.StandardErrorLine);
        using var registration = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
            }
        });

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            var stdout = await stdoutTask.ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);
            return new ProcessResult(process.ExitCode, stdout.Text, stderr.Text, stdout.Binary);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
            }

            await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
            throw;
        }
    }

    private static async Task<(string Text, byte[] Binary)> ReadTextAsync(StreamReader reader, Action<string>? onLine)
    {
        var output = new StringBuilder();
        var line = new StringBuilder();
        var buffer = new char[4096];
        int read;
        while ((read = await reader.ReadAsync(buffer).ConfigureAwait(false)) > 0)
        {
            output.Append(buffer, 0, read);
            for (var index = 0; index < read; index++)
            {
                var character = buffer[index];
                if (character is '\r' or '\n')
                {
                    if (line.Length > 0)
                    {
                        onLine?.Invoke(line.ToString());
                        line.Clear();
                    }
                }
                else
                {
                    line.Append(character);
                }
            }
        }

        if (line.Length > 0)
        {
            onLine?.Invoke(line.ToString());
        }

        return (output.ToString(), []);
    }

    private static async Task<(string Text, byte[] Binary)> ReadBinaryAsync(Stream stream)
    {
        using var memory = new MemoryStream();
        await stream.CopyToAsync(memory).ConfigureAwait(false);
        return (string.Empty, memory.ToArray());
    }
}
