using RightClip.Core.Media;

namespace RightClip.Core.Operations;

public enum TrimMode
{
    Start,
    End,
    Range,
    Scene
}

public enum TimeInputKind
{
    DurationOffset,
    ClockTime
}

public enum CutEncoding
{
    KeyframeSafe,
    FastCopy
}

public sealed record TrimRequest(
    TrimMode Mode,
    TimeSpan Start,
    TimeSpan? End = null,
    TimeInputKind StartKind = TimeInputKind.DurationOffset,
    TimeInputKind EndKind = TimeInputKind.DurationOffset,
    int SceneSensitivity = 60,
    CutEncoding Encoding = CutEncoding.KeyframeSafe);

public sealed record TrimFilePlan(
    MediaInfo Media,
    TimeSpan RequestedStart,
    TimeSpan LandedStart,
    TimeSpan RequestedEnd,
    string OutputPath,
    CutEncoding Encoding = CutEncoding.KeyframeSafe)
{
    public TimeSpan OutputDuration => RequestedEnd - LandedStart;
}

public sealed record SceneClipPlan(
    int Number,
    TimeSpan RequestedStart,
    TimeSpan LandedStart,
    TimeSpan End,
    byte[] Thumbnail,
    string OutputPath);

public sealed record SceneFilePlan(MediaInfo Media, IReadOnlyList<SceneClipPlan> Clips, CutEncoding Encoding = CutEncoding.KeyframeSafe);

public sealed record TrackSelection(string CodecType, int Ordinal, bool Keep, string? Title = null);

public sealed record SubtitleInput(string Path, string? Title = null, string? Language = null);

public sealed record TrackRequest(
    IReadOnlyList<TrackSelection> Tracks,
    IReadOnlyList<SubtitleInput> AddedSubtitles,
    bool ExtractSelectedSubtitles = false);

public sealed record SubtitleExtractionPlan(MediaInfo Media, MediaStream Stream, string OutputPath);

public sealed record TrackFilePlan(MediaInfo Media, string? OutputPath, IReadOnlyList<SubtitleExtractionPlan> Extractions);

public sealed record DetailsRequest(
    IReadOnlyDictionary<string, string> Tags,
    IReadOnlyList<ChapterInfo> Chapters,
    int? Rotation,
    bool FastStart,
    bool StripLocation);

public sealed record DetailsFilePlan(MediaInfo Media, string OutputPath);
