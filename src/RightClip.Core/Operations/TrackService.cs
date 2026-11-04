using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed class TrackService
{
    private readonly FFmpegExecutor _ffmpeg;

    public TrackService(FFmpegExecutor ffmpeg)
    {
        _ffmpeg = ffmpeg;
    }

    public IReadOnlyList<TrackFilePlan> CreatePlans(
        IReadOnlyList<MediaInfo> mediaFiles,
        TrackRequest request,
        OutputAllocator outputs)
    {
        if (mediaFiles.Count == 0)
        {
            throw new InvalidOperationException("Select at least one video.");
        }

        foreach (var subtitle in request.AddedSubtitles)
        {
            if (!File.Exists(subtitle.Path))
            {
                throw new FileNotFoundException("An added subtitle file was not found.", subtitle.Path);
            }
        }

        return mediaFiles.Select(media => request.ExtractSelectedSubtitles
            ? CreateExtractionPlan(media, request, outputs)
            : CreateRemuxPlan(media, request, outputs)).ToArray();
    }

    public Task<IReadOnlyList<FileOperationResult>> RunAsync(
        IReadOnlyList<TrackFilePlan> plans,
        TrackRequest request,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken = default) =>
        BatchRunner.RunAsync(plans, plan => plan.Media.SourcePath,
            (plan, token) => request.ExtractSelectedSubtitles
                ? RunExtractionsAsync(plan, token)
                : RunRemuxAsync(plan, request, progress, token), progress, cancellationToken);

    private static TrackFilePlan CreateRemuxPlan(MediaInfo media, TrackRequest request, OutputAllocator outputs)
    {
        ResolveSelections(media, request);
        return new TrackFilePlan(media, outputs.Allocate(media.SourcePath, ".tracks"), []);
    }

    private static TrackFilePlan CreateExtractionPlan(MediaInfo media, TrackRequest request, OutputAllocator outputs)
    {
        if (request.AddedSubtitles.Count > 0)
        {
            throw new InvalidOperationException("Subtitles cannot be added during extraction.");
        }

        var selections = request.Tracks.Where(track => track.Keep && track.CodecType == "subtitle").ToArray();
        if (selections.Length == 0)
        {
            throw new InvalidOperationException("Select at least one soft subtitle stream to extract.");
        }

        var subtitles = media.SubtitleStreams.ToDictionary(stream => stream.Ordinal);
        var plans = new List<SubtitleExtractionPlan>();
        var extractionNumber = 0;
        foreach (var selection in selections)
        {
            if (!subtitles.TryGetValue(selection.Ordinal, out var stream))
            {
                throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} does not contain subtitle {selection.Ordinal + 1}.");
            }

            extractionNumber++;
            var extension = SubtitleExtension(stream.CodecName);
            plans.Add(new SubtitleExtractionPlan(media, stream, outputs.Allocate(media.SourcePath, $".subtitle{extractionNumber:00}", extension)));
        }

        return new TrackFilePlan(media, null, plans);
    }

    private static IReadOnlyDictionary<string, TrackSelection> ResolveSelections(MediaInfo media, TrackRequest request)
    {
        var selections = request.Tracks.ToDictionary(track => Key(track.CodecType, track.Ordinal), StringComparer.OrdinalIgnoreCase);
        var available = media.Streams.Where(stream => stream.CodecType is "audio" or "subtitle")
            .Select(stream => Key(stream.CodecType, stream.Ordinal)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missing = selections.Keys.FirstOrDefault(key => !available.Contains(key));
        if (missing is not null)
        {
            throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} does not contain the selected {missing.Replace(':', ' ')} stream.");
        }

        return selections;
    }

    private async Task<IReadOnlyList<string>> RunRemuxAsync(TrackFilePlan plan, TrackRequest request, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var outputPath = plan.OutputPath ?? throw new InvalidOperationException("The remux plan has no output path.");
        var media = plan.Media;
        var selections = ResolveSelections(media, request);
        var arguments = new List<string> { "-i", media.SourcePath };
        foreach (var subtitle in request.AddedSubtitles)
        {
            arguments.AddRange(["-i", Path.GetFullPath(subtitle.Path)]);
        }

        foreach (var stream in media.Streams.Where(stream => stream.CodecType is not ("audio" or "subtitle")))
        {
            arguments.AddRange(["-map", $"0:{stream.Index}"]);
        }

        var audioOutput = 0;
        var subtitleOutput = 0;
        foreach (var stream in media.Streams.Where(stream => stream.CodecType is "audio" or "subtitle"))
        {
            selections.TryGetValue(Key(stream.CodecType, stream.Ordinal), out var selection);
            if (selection?.Keep == false)
            {
                continue;
            }

            arguments.AddRange(["-map", $"0:{stream.Index}"]);
            if (stream.CodecType == "audio")
            {
                if (selection?.Title is not null)
                {
                    arguments.AddRange([$"-metadata:s:a:{audioOutput}", $"title={selection.Title}"]);
                }

                audioOutput++;
            }
            else
            {
                if (selection?.Title is not null)
                {
                    arguments.AddRange([$"-metadata:s:s:{subtitleOutput}", $"title={selection.Title}"]);
                }

                subtitleOutput++;
            }
        }

        var subtitleCodecs = new List<(int Ordinal, string Encoder)>();
        for (var index = 0; index < request.AddedSubtitles.Count; index++)
        {
            var subtitle = request.AddedSubtitles[index];
            arguments.AddRange(["-map", $"{index + 1}:s:0"]);
            subtitleCodecs.Add((subtitleOutput, SubtitleEncoder(media.SourcePath)));
            if (subtitle.Title is not null)
            {
                arguments.AddRange([$"-metadata:s:s:{subtitleOutput}", $"title={subtitle.Title}"]);
            }

            if (!string.IsNullOrWhiteSpace(subtitle.Language))
            {
                arguments.AddRange([$"-metadata:s:s:{subtitleOutput}", $"language={subtitle.Language}"]);
            }

            subtitleOutput++;
        }

        arguments.AddRange(["-map_metadata", "0", "-map_chapters", "0", "-c", "copy"]);
        foreach (var (ordinal, encoder) in subtitleCodecs)
        {
            arguments.AddRange([$"-c:s:{ordinal}", encoder]);
        }

        arguments.Add(outputPath);
        await _ffmpeg.RunWithProgressAsync(arguments, media.Duration, media.SourcePath, progress, cancellationToken).ConfigureAwait(false);
        return [outputPath];
    }

    private async Task<IReadOnlyList<string>> RunExtractionsAsync(TrackFilePlan plan, CancellationToken cancellationToken)
    {
        var outputs = new List<string>();
        try
        {
            foreach (var extraction in plan.Extractions)
            {
                var output = extraction.OutputPath;
                var convertToSubrip = string.Equals(extraction.Stream.CodecName, "mov_text", StringComparison.OrdinalIgnoreCase);
                var arguments = new List<string> { "-i", plan.Media.SourcePath, "-map", $"0:{extraction.Stream.Index}",
                "-c:s", convertToSubrip ? "srt" : "copy", output };
                await _ffmpeg.RunOutputAsync(arguments, cancellationToken).ConfigureAwait(false);
                outputs.Add(output);
            }

            return outputs;
        }
        catch (Exception exception)
        {
            FFmpegExecutor.DeleteFailedOutputs(outputs, exception);
            throw;
        }
    }

    internal static string SubtitleEncoder(string outputPath) => Path.GetExtension(outputPath).ToLowerInvariant() switch
    {
        ".mp4" or ".mov" => "mov_text",
        ".webm" => "webvtt",
        _ => "copy"
    };

    private static string SubtitleExtension(string codecName) => codecName.ToLowerInvariant() switch
    {
        "ass" or "ssa" => ".ass",
        "webvtt" => ".vtt",
        "subrip" or "mov_text" or "text" => ".srt",
        _ => ".mks"
    };

    private static string Key(string codecType, int ordinal) => $"{codecType}:{ordinal}";
}
