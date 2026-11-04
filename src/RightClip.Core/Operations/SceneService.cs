using System.Globalization;
using System.Text.RegularExpressions;
using RightClip.Core.Media;
using RightClip.Core.Processes;

namespace RightClip.Core.Operations;

public sealed partial class SceneService
{
    private readonly MediaProbe _probe;
    private readonly FFmpegExecutor _ffmpeg;

    public SceneService(MediaProbe probe, FFmpegExecutor ffmpeg)
    {
        _probe = probe;
        _ffmpeg = ffmpeg;
    }

    public async Task<IReadOnlyList<SceneFilePlan>> CreatePlansAsync(
        IReadOnlyList<MediaInfo> mediaFiles,
        int sensitivity,
        OutputAllocator outputs,
        CancellationToken cancellationToken = default,
        CutEncoding encoding = CutEncoding.KeyframeSafe)
    {
        if (mediaFiles.Count == 0)
        {
            throw new InvalidOperationException("Select at least one video.");
        }

        if (sensitivity is < 1 or > 100)
        {
            throw new InvalidOperationException("Scene sensitivity must be between 1 and 100.");
        }

        var plans = new List<SceneFilePlan>();
        foreach (var media in mediaFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (media.PrimaryVideo is null)
            {
                throw new InvalidOperationException($"{Path.GetFileName(media.SourcePath)} has no video stream.");
            }

            var cuts = await DetectCutsAsync(media, sensitivity, cancellationToken).ConfigureAwait(false);
            var boundaries = new List<TimeSpan> { TimeSpan.Zero };
            boundaries.AddRange(cuts.Where(cut => cut > TimeSpan.FromMilliseconds(50) && media.Duration - cut > TimeSpan.FromMilliseconds(50)));
            boundaries.Add(media.Duration);
            boundaries = boundaries.Distinct().OrderBy(value => value).ToList();
            var keyframes = encoding == CutEncoding.FastCopy
                ? await _probe.GetKeyframesAsync(media.SourcePath, cancellationToken).ConfigureAwait(false)
                : [];
            var clips = new List<SceneClipPlan>();
            for (var index = 0; index < boundaries.Count - 1; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var start = boundaries[index];
                var end = boundaries[index + 1];
                if (end - start < TimeSpan.FromMilliseconds(50))
                {
                    continue;
                }

                var landed = encoding == CutEncoding.FastCopy ? MediaProbe.SnapToPreviousKeyframe(start, keyframes) : start;
                var thumbnailTime = start + TimeSpan.FromMilliseconds(Math.Min(100, (end - start).TotalMilliseconds / 2));
                var thumbnail = await CreateThumbnailAsync(media.SourcePath, thumbnailTime, cancellationToken).ConfigureAwait(false);
                clips.Add(new SceneClipPlan(clips.Count + 1, start, landed, end, thumbnail, outputs.Allocate(media.SourcePath, $".scene{clips.Count + 1:00}")));
            }

            if (clips.Count == 0)
            {
                throw new InvalidOperationException($"No usable scenes were found in {Path.GetFileName(media.SourcePath)}.");
            }

            plans.Add(new SceneFilePlan(media, clips, encoding));
        }

        return plans;
    }

    public Task<IReadOnlyList<FileOperationResult>> RunAsync(
        IReadOnlyList<SceneFilePlan> plans,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken = default) =>
        BatchRunner.RunAsync(plans, plan => plan.Media.SourcePath, (plan, token) => RunFileAsync(plan, progress, token), progress, cancellationToken);

    internal static double ThresholdFromSensitivity(int sensitivity) => 0.6 - sensitivity * 0.005;

    internal static IReadOnlyList<TimeSpan> ParseSceneTimes(string ffmpegOutput)
    {
        var times = new List<TimeSpan>();
        foreach (Match match in SceneTimePattern().Matches(ffmpegOutput))
        {
            if (double.TryParse(match.Groups["time"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && seconds >= 0)
            {
                times.Add(TimeSpan.FromSeconds(seconds));
            }
        }

        return times.Distinct().OrderBy(value => value).ToArray();
    }

    private async Task<IReadOnlyList<TimeSpan>> DetectCutsAsync(MediaInfo media, int sensitivity, CancellationToken cancellationToken)
    {
        var threshold = ThresholdFromSensitivity(sensitivity).ToString("0.###", CultureInfo.InvariantCulture);
        var output = new System.Text.StringBuilder();
        try
        {
            await _ffmpeg.RunAsync(["-i", media.SourcePath, "-map", "0:v:0", "-vf", $"select=gt(scene\\,{threshold}),showinfo",
                "-an", "-sn", "-dn", "-f", "null", "-"], cancellationToken,
                errorLine: line => output.AppendLine(line)).ConfigureAwait(false);
        }
        catch (InvalidOperationException exception)
        {
            throw new InvalidOperationException($"Scene detection failed for {Path.GetFileName(media.SourcePath)}: {exception.Message}", exception);
        }

        return ParseSceneTimes(output.ToString());
    }

    private async Task<byte[]> CreateThumbnailAsync(string sourcePath, TimeSpan timestamp, CancellationToken cancellationToken)
    {
        var bytes = await _ffmpeg.ReadBinaryAsync(["-ss", MediaTime.FFmpeg(timestamp), "-i", sourcePath, "-map", "0:v:0",
            "-frames:v", "1", "-vf", "scale=320:180:force_original_aspect_ratio=decrease", "-c:v", "png", "-f", "image2pipe", "pipe:1"], cancellationToken).ConfigureAwait(false);
        if (bytes.Length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4e || bytes[3] != 0x47)
        {
            throw new InvalidOperationException("FFmpeg did not create a valid scene thumbnail.");
        }

        return bytes;
    }

    private async Task<IReadOnlyList<string>> RunFileAsync(SceneFilePlan plan, IProgress<OperationProgress>? progress, CancellationToken cancellationToken)
    {
        var outputs = new List<string>();
        try
        {
            foreach (var clip in plan.Clips)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var duration = clip.End - clip.LandedStart;
                var arguments = new List<string>();
                if (clip.LandedStart > TimeSpan.Zero)
                {
                    arguments.AddRange(["-ss", MediaTime.FFmpeg(clip.LandedStart)]);
                }

                arguments.AddRange(["-i", plan.Media.SourcePath, "-t", MediaTime.FFmpeg(duration), "-map", "0",
                "-map_metadata", "0", "-map_chapters", "0"]);
                if (plan.Encoding == CutEncoding.KeyframeSafe)
                {
                    arguments.AddRange(["-c", "copy"]);
                    arguments.AddRange(VideoEncoding.GetKeyframeArguments(plan.Media));
                }
                else
                {
                    arguments.AddRange(["-c", "copy"]);
                }

                arguments.Add(clip.OutputPath);
                await _ffmpeg.RunWithProgressAsync(arguments, duration, plan.Media.SourcePath, progress, cancellationToken).ConfigureAwait(false);
                outputs.Add(clip.OutputPath);
            }

            return outputs;
        }
        catch (Exception exception)
        {
            FFmpegExecutor.DeleteFailedOutputs(outputs, exception);
            throw;
        }
    }

    [GeneratedRegex(@"pts_time:(?<time>\d+(?:\.\d+)?)", RegexOptions.CultureInvariant)]
    private static partial Regex SceneTimePattern();
}
