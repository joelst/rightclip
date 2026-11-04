using RightClip.Core.Media;

namespace RightClip.Core.Operations;

public static class VideoEncoding
{
    public static IReadOnlyList<string> GetKeyframeArguments(MediaInfo media)
    {
        var codec = media.PrimaryVideo?.CodecName ?? throw new InvalidOperationException("The source has no video stream.");
        var bitrate = media.PrimaryVideo!.BitRate is { } value && value > 0
            ? value.ToString(System.Globalization.CultureInfo.InvariantCulture)
            : "5000000";
        return codec.ToLowerInvariant() switch
        {
            "h264" => ["-c:v:0", "libopenh264", "-b:v", bitrate, "-force_key_frames:v:0", "0"],
            "hevc" or "h265" => ["-c:v:0", "libkvazaar", "-b:v", bitrate, "-force_key_frames:v:0", "0"],
            "vp8" => ["-c:v:0", "libvpx", "-crf", "10", "-b:v", "0", "-force_key_frames:v:0", "0"],
            "vp9" => ["-c:v:0", "libvpx-vp9", "-crf", "18", "-b:v", "0", "-force_key_frames:v:0", "0"],
            "av1" => ["-c:v:0", "libaom-av1", "-crf", "20", "-b:v", "0", "-force_key_frames:v:0", "0"],
            "mpeg4" => ["-c:v:0", "mpeg4", "-q:v", "2", "-force_key_frames:v:0", "0"],
            "mpeg2video" => ["-c:v:0", "mpeg2video", "-q:v", "2", "-force_key_frames:v:0", "0"],
            "mjpeg" => ["-c:v:0", "mjpeg", "-q:v", "2", "-force_key_frames:v:0", "0"],
            _ => throw new NotSupportedException($"Keyframe-safe cutting does not support {codec}. Use Fast stream copy for this file.")
        };
    }
}
