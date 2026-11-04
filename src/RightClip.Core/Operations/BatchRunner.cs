using RightClip.Core.Media;

namespace RightClip.Core.Operations;

public static class BatchRunner
{
    public static async Task<IReadOnlyList<FileOperationResult>> RunAsync<T>(
        IReadOnlyList<T> items,
        Func<T, string> sourcePath,
        Func<T, CancellationToken, Task<IReadOnlyList<string>>> action,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        var results = new List<FileOperationResult>();
        foreach (var item in items)
        {
            var source = sourcePath(item);
            if (cancellationToken.IsCancellationRequested)
            {
                results.Add(new FileOperationResult(source, false, [], "Cancelled.", true));
                continue;
            }

            try
            {
                progress?.Report(new OperationProgress(source, "Running"));
                var outputs = await action(item, cancellationToken).ConfigureAwait(false);
                results.Add(new FileOperationResult(source, true, outputs));
                progress?.Report(new OperationProgress(source, "Complete", 1));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                results.Add(new FileOperationResult(source, false, [], "Cancelled.", true));
                progress?.Report(new OperationProgress(source, "Cancelled"));
            }
            catch (Exception exception)
            {
                results.Add(new FileOperationResult(source, false, [], exception.Message));
                progress?.Report(new OperationProgress(source, "Failed"));
            }
        }

        return results;
    }
}
