using System.Globalization;
using System.Text.RegularExpressions;

namespace RightClip.Core.Media;

public static partial class MediaTime
{
    public static TimeSpan Parse(string value)
    {
        if (!TryParse(value, out var result))
        {
            throw new FormatException($"'{value}' is not a valid time. Use seconds, MM:SS, or HH:MM:SS.");
        }

        return result;
    }

    public static bool TryParse(string? value, out TimeSpan result)
    {
        result = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        value = value.Trim();
        if (double.TryParse(value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var seconds) &&
            double.IsFinite(seconds) && seconds >= 0 && seconds <= TimeSpan.MaxValue.TotalSeconds)
        {
            result = TimeSpan.FromSeconds(seconds);
            return true;
        }

        var match = ClockPattern().Match(value);
        if (!match.Success)
        {
            return false;
        }

        long hours = 0;
        if ((match.Groups["hours"].Success && !long.TryParse(match.Groups["hours"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out hours)) ||
            !long.TryParse(match.Groups["minutes"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var minutes) ||
            !long.TryParse(match.Groups["seconds"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var wholeSeconds) ||
            (match.Groups["hours"].Success && minutes >= 60) || wholeSeconds >= 60)
        {
            return false;
        }

        var fraction = match.Groups["fraction"].Success ? match.Groups["fraction"].Value : string.Empty;
        if (!double.TryParse($"0{fraction}", NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var fractionalSeconds))
        {
            return false;
        }

        try
        {
            checked
            {
                result = TimeSpan.FromHours(hours) + TimeSpan.FromMinutes(minutes) +
                    TimeSpan.FromSeconds(wholeSeconds) + TimeSpan.FromSeconds(fractionalSeconds);
            }
        }
        catch (OverflowException)
        {
            return false;
        }

        return true;
    }

    public static string Display(TimeSpan value)
    {
        var wholeHours = (long)value.TotalHours;
        return string.Create(CultureInfo.InvariantCulture, $"{wholeHours:00}:{value.Minutes:00}:{value.Seconds:00}.{value.Milliseconds:000}");
    }

    public static string FFmpeg(TimeSpan value) => value.TotalSeconds.ToString("0.########", CultureInfo.InvariantCulture);

    [GeneratedRegex(@"^(?:(?<hours>\d+):)?(?<minutes>\d+):(?<seconds>\d+)(?<fraction>\.\d{1,7})?$", RegexOptions.CultureInvariant)]
    private static partial Regex ClockPattern();
}
