using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed class TrimService
{
    private readonly MediaProbe _probe;
    private readonly FFmpegExecutor _ffmpeg;

    public TrimService(MediaProbe probe, FFmpegExecutor ffmpeg)
    {
        _probe = probe;
        _ffmpeg = ffmpeg;
    }

    public async Task<IReadOnlyList<TrimFilePlan>> CreatePlansAsync(
        IReadOnlyList<MediaInfo> mediaFiles,
        TrimRequest request,
        OutputAllocator outputs,
        CancellationToken cancellationToken = default)
    {
        if (mediaFiles.Count == 0)
        {
            throw new InvalidOperationException("Select at least one video.");
        }

        if (request.Mode == TrimMode.Scene)
        {
            throw new InvalidOperationException("Scene splitting requires a scene review plan.");
        }

        var ranges = mediaFiles.Select(media => ResolveRange(media, request)).ToArray();
        var plans = new List<TrimFilePlan>();
        foreach (var (media, range) in mediaFiles.Zip(ranges))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var landed = request.Encoding == CutEncoding.KeyframeSafe || range.Start == TimeSpan.Zero
                ? range.Start
                : MediaProbe.SnapToPreviousKeyframe(range.Start, await _probe.GetKeyframesAsync(media.SourcePath, cancellationToken).ConfigureAwait(false));
            if (landed >= range.End)
            {
                throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} has no usable keyframe before the requested range.");
            }

            plans.Add(new TrimFilePlan(media, range.Start, landed, range.End, outputs.Allocate(media.SourcePath, ".trimmed"), request.Encoding));
        }

        return plans;
    }

    public Task<IReadOnlyList<FileOperationResult>> RunAsync(
        IReadOnlyList<TrimFilePlan> plans,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken = default) =>
        BatchRunner.RunAsync(plans, plan => plan.Media.SourcePath, (plan, token) => RunFileAsync(plan, progress, token), progress, cancellationToken);

    internal static (TimeSpan Start, TimeSpan End) ResolveRange(MediaInfo media, TrimRequest request)
    {
        if (media.PrimaryVideo is null)
        {
            throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} has no video stream.");
        }

        switch (request.Mode)
        {
            case TrimMode.Start:
            {
                var start = request.Start;
                if (start <= TimeSpan.Zero || start >= media.Duration)
                {
                    throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} is {MediaTime.Display(media.Duration)} long. The start time must be greater than zero and shorter than the video.");
                }

                return (start, media.Duration);
            }
            case TrimMode.End:
            {
                if (request.End is not { } amount || amount <= TimeSpan.Zero)
                {
                    throw new InvalidOperationException("Enter an end time or a duration greater than zero.");
                }

                var end = request.EndKind == TimeInputKind.DurationOffset ? media.Duration - amount : amount;
                if (end <= TimeSpan.Zero || end > media.Duration)
                {
                    throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} is {MediaTime.Display(media.Duration)} long. The requested end is outside the video.");
                }

                return (TimeSpan.Zero, end);
            }
            case TrimMode.Range:
            {
                if (request.End is not { } end || request.Start >= end || end > media.Duration)
                {
                    throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} is {MediaTime.Display(media.Duration)} long. Keep a range with an earlier start and an end inside the video.");
                }

                return (request.Start, end);
            }
            default:
                throw new InvalidOperationException("Choose Trim start, Trim end, or Keep a range.");
        }
    }

    private async Task<IReadOnlyList<string>> RunFileAsync(TrimFilePlan plan, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var arguments = new List<string>();
        if (plan.LandedStart > TimeSpan.Zero)
        {
            arguments.AddRange(["-ss", MediaTime.FFmpeg(plan.LandedStart)]);
        }

        arguments.AddRange(["-i", plan.Media.SourcePath, "-t", MediaTime.FFmpeg(plan.OutputDuration),
            "-map", "0", "-map_metadata", "0", "-map_chapters", "0"]);
        if (plan.Encoding == CutEncoding.KeyframeSafe)
        {
            arguments.AddRange(["-c", "copy"]);
            arguments.AddRange(VideoEncoding.GetKeyframeArguments(plan.Media));
        }
        else
        {
            arguments.AddRange(["-c", "copy"]);
        }

        arguments.Add(plan.OutputPath);
        await _ffmpeg.RunWithProgressAsync(arguments, plan.OutputDuration, plan.Media.SourcePath, progress, cancellationToken).ConfigureAwait(false);
        return [plan.OutputPath];
    }
}
