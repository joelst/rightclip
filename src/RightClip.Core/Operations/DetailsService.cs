using System.Globalization;
using System.Text;
using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed class DetailsService
{
    private static readonly HashSet<string> LocationTags = new(StringComparer.OrdinalIgnoreCase)
    {
        "location", "location-eng", "com.apple.quicktime.location.ISO6709"
    };

    private readonly FFmpegExecutor _ffmpeg;

    public DetailsService(FFmpegExecutor ffmpeg)
    {
        _ffmpeg = ffmpeg;
    }

    public IReadOnlyList<DetailsFilePlan> CreatePlans(IReadOnlyList<MediaInfo> mediaFiles, DetailsRequest request, OutputAllocator outputs)
    {
        if (mediaFiles.Count == 0)
        {
            throw new InvalidOperationException("Select at least one video.");
        }

        if (request.Rotation is not null && request.Rotation is not (0 or 90 or 180 or 270))
        {
            throw new InvalidOperationException("Rotation must be unchanged, 0, 90, 180, or 270 degrees.");
        }

        if (request.FastStart && mediaFiles.Any(media =>
            !Path.GetExtension(media.SourcePath).Equals(".mp4", StringComparison.OrdinalIgnoreCase) &&
            !Path.GetExtension(media.SourcePath).Equals(".mov", StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException("Fast start applies only to MP4 and MOV files.");
        }

        foreach (var media in mediaFiles)
        {
            ValidateChapters(media, request.Chapters);
        }

        return mediaFiles.Select(media => new DetailsFilePlan(media, outputs.Allocate(media.SourcePath, ".details"))).ToArray();
    }

    public Task<IReadOnlyList<FileOperationResult>> RunAsync(
        IReadOnlyList<DetailsFilePlan> plans,
        DetailsRequest request,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken = default) =>
        BatchRunner.RunAsync(plans, plan => plan.Media.SourcePath,
            (plan, token) => RunFileAsync(plan, request, progress, token), progress, cancellationToken);

    internal async Task<IReadOnlyList<string>> RemoveMetadataAsync(
        MediaInfo media, string outputPath, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var arguments = new List<string>();
        if (media.PrimaryVideo is not null)
        {
            arguments.AddRange(["-display_rotation:v", "0"]);
        }

        arguments.AddRange(["-i", media.SourcePath, "-map", "0", "-map_metadata", "-1", "-map_metadata:s", "-1",
            "-map_chapters", "-1", "-c", "copy", "-fflags", "+bitexact",
            "-metadata", "encoder=", "-metadata:s", "encoder=", outputPath]);
        progress?.Report(new OperationProgress(media.SourcePath, "Removing metadata"));
        await _ffmpeg.RunWithProgressAsync(arguments, media.Duration, media.SourcePath, progress, cancellationToken).ConfigureAwait(false);
        return [outputPath];
    }

    internal static string BuildMetadata(DetailsRequest request)
    {
        var metadata = new StringBuilder(";FFMETADATA1\n");
        foreach (var tag in request.Tags.OrderBy(tag => tag.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (request.StripLocation && LocationTags.Contains(tag.Key))
            {
                continue;
            }

            if (string.IsNullOrWhiteSpace(tag.Key))
            {
                continue;
            }

            metadata.Append(Escape(tag.Key)).Append('=').Append(Escape(tag.Value)).Append('\n');
        }

        foreach (var chapter in request.Chapters)
        {
            metadata.Append("[CHAPTER]\nTIMEBASE=1/1000\n");
            metadata.Append("START=").Append(((long)chapter.Start.TotalMilliseconds).ToString(CultureInfo.InvariantCulture)).Append('\n');
            metadata.Append("END=").Append(((long)chapter.End.TotalMilliseconds).ToString(CultureInfo.InvariantCulture)).Append('\n');
            metadata.Append("title=").Append(Escape(chapter.Title)).Append('\n');
        }

        return metadata.ToString();
    }

    private static void ValidateChapters(MediaInfo media, IReadOnlyList<ChapterInfo> chapters)
    {
        var previousEnd = TimeSpan.Zero;
        foreach (var chapter in chapters)
        {
            if (chapter.Start < previousEnd || chapter.End <= chapter.Start || chapter.End > media.Duration + TimeSpan.FromSeconds(1))
            {
                throw new InvalidOperationException($"Chapters for {Path.GetFileName(media.SourcePath)} must be ordered, have positive durations, and stay inside the video.");
            }

            previousEnd = chapter.End;
        }
    }

    private async Task<IReadOnlyList<string>> RunFileAsync(DetailsFilePlan plan, DetailsRequest request, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var temporaryDirectory = Path.Combine(Path.GetTempPath(), "RightClip", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporaryDirectory);
        var metadataPath = Path.Combine(temporaryDirectory, "details.txt");
        try
        {
            await File.WriteAllTextAsync(metadataPath, BuildMetadata(request), new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            var arguments = new List<string>();
            if (request.Rotation is { } rotation)
            {
                arguments.AddRange(["-display_rotation:v:0", rotation.ToString(CultureInfo.InvariantCulture)]);
            }

            arguments.AddRange(["-i", plan.Media.SourcePath, "-f", "ffmetadata", "-i", metadataPath,
                "-map", "0", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy"]);

            if (request.FastStart)
            {
                arguments.AddRange(["-movflags", "+faststart"]);
            }

            arguments.Add(plan.OutputPath);
            await _ffmpeg.RunWithProgressAsync(arguments, plan.Media.Duration, plan.Media.SourcePath, progress, cancellationToken).ConfigureAwait(false);
            return [plan.OutputPath];
        }
        finally
        {
            try
            {
                Directory.Delete(temporaryDirectory, true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static string Escape(string value) => value
        .Replace("\\", "\\\\", StringComparison.Ordinal)
        .Replace("=", "\\=", StringComparison.Ordinal)
        .Replace(";", "\\;", StringComparison.Ordinal)
        .Replace("#", "\\#", StringComparison.Ordinal)
        .Replace("\r", "\\\n", StringComparison.Ordinal)
        .Replace("\n", "\\\n", StringComparison.Ordinal);
}
