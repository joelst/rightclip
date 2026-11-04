using RightClip.Core.Media;

namespace RightClip.Core.Operations;

public static class BatchRunner
{
    public static async Task<IReadOnlyList<FileOperationResult>> RunAsync<T>(
        IReadOnlyList<T> items,
        Func<T, string> sourcePath,
        Func<T, CancellationToken, Task<IReadOnlyList<string>>> action,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken,
        int maxConcurrency = 2)
    {
        if (maxConcurrency < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maxConcurrency));
        }

        using var limiter = new SemaphoreSlim(maxConcurrency, maxConcurrency);
        var results = new FileOperationResult[items.Count];
        var tasks = items.Select(async (item, index) =>
        {
            var source = sourcePath(item);
            try
            {
                await limiter.WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                results[index] = new FileOperationResult(source, false, [], "Cancelled.", true);
                return;
            }

            try
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    results[index] = new FileOperationResult(source, false, [], "Cancelled.", true);
                    return;
                }

                try
                {
                    progress?.Report(new OperationProgress(source, "Running"));
                    var outputs = await action(item, cancellationToken).ConfigureAwait(false);
                    results[index] = new FileOperationResult(source, true, outputs);
                    progress?.Report(new OperationProgress(source, "Complete", 1));
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    results[index] = new FileOperationResult(source, false, [], "Cancelled.", true);
                    progress?.Report(new OperationProgress(source, "Cancelled"));
                }
                catch (Exception exception)
                {
                    results[index] = new FileOperationResult(source, false, [], exception.Message);
                    progress?.Report(new OperationProgress(source, "Failed"));
                }
            }
            finally
            {
                limiter.Release();
            }
        }).ToArray();

        await Task.WhenAll(tasks).ConfigureAwait(false);
        return results;
    }
}
