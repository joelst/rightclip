using System.IO;
using System.Text.Json;

namespace RightClip.App;

public sealed record UserSettings(string? FFmpegDirectory = null, int SceneSensitivity = 60, bool SuppressCompletionNotification = false);

public static class SettingsStore
{
    private static string SettingsPath => Environment.GetEnvironmentVariable("RIGHTCLIP_SETTINGS_PATH") ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RightClip", "settings.json");

    public static UserSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new UserSettings();
            }

            var settings = JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(SettingsPath));
            return settings is null || settings.SceneSensitivity is < 1 or > 100
                ? new UserSettings()
                : settings;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new UserSettings();
        }
    }

    public static void Save(UserSettings settings)
    {
        var directory = Path.GetDirectoryName(SettingsPath) ?? throw new InvalidOperationException("Settings could not be saved.");
        Directory.CreateDirectory(directory);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }
}
