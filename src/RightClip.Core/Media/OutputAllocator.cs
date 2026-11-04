namespace RightClip.Core.Media;

public sealed class OutputAllocator
{
    private readonly HashSet<string> _reserved = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();

    public string Allocate(string sourcePath, string suffix, string? extension = null)
    {
        var source = Path.GetFullPath(sourcePath);
        var directory = Path.GetDirectoryName(source) ?? throw new InvalidOperationException("The source has no parent directory.");
        var stem = Path.GetFileNameWithoutExtension(source);
        extension ??= Path.GetExtension(source);
        if (string.IsNullOrWhiteSpace(suffix) || suffix.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            throw new ArgumentException("A valid output suffix is required.", nameof(suffix));
        }

        lock (_sync)
        {
            for (var number = 1; ; number++)
            {
                var numberSuffix = number == 1 ? string.Empty : $" ({number})";
                var candidate = Path.Combine(directory, $"{stem}{suffix}{numberSuffix}{extension}");
                if (string.Equals(candidate, source, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("An output cannot replace its source.");
                }

                if (!File.Exists(candidate) && !Directory.Exists(candidate) && _reserved.Add(candidate))
                {
                    return candidate;
                }
            }
        }
    }
}
