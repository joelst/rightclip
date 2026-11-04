using RightClip.Core.Media;

namespace RightClip.Core.Launch;

public sealed record WorkerArguments(string Action, IReadOnlyList<string> Paths)
{
    public static WorkerArguments Parse(IReadOnlyList<string> arguments)
    {
        var action = "trim";
        var paths = new List<string>();
        for (var index = 0; index < arguments.Count; index++)
        {
            var argument = arguments[index];
            switch (argument)
            {
                case "--action" when index + 1 < arguments.Count:
                    action = arguments[++index].ToLowerInvariant();
                    break;
                case "--path" when index + 1 < arguments.Count:
                    paths.Add(arguments[++index]);
                    break;
                default:
                    if (argument.StartsWith("--", StringComparison.Ordinal))
                    {
                        throw new ArgumentException($"Unknown or incomplete option: {argument}");
                    }

                    paths.Add(argument);
                    break;
            }
        }

        if (action is not ("trim" or "tracks" or "details" or "remove-metadata"))
        {
            throw new ArgumentException("The action must be trim, tracks, details, or remove-metadata.");
        }

        var normalized = paths.Select(SupportedMedia.NormalizeSource)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return new WorkerArguments(action, normalized);
    }
}
