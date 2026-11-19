using System.IO;
using System.Text.Json;

namespace RightClip.App;

public sealed record UserSettings(string? FFmpegDirectory = null, int SceneSensitivity = 60, bool SuppressCompletionNotification = false);

public static class SettingsStore
{
    private const string SettingsMutexName = @"Local\RightClip.Settings";
    private static string SettingsPath => Environment.GetEnvironmentVariable("RIGHTCLIP_SETTINGS_PATH") ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RightClip", "settings.json");

    public static UserSettings Load() => WithSettingsLock(LoadUnlocked);

    public static void Save(UserSettings settings) => WithSettingsLock(() => Write(settings));

    public static UserSettings SaveChanges(UserSettings original, UserSettings updated) => WithSettingsLock(() =>
    {
        var latest = LoadUnlocked();
        var merged = latest with
        {
            FFmpegDirectory = original.FFmpegDirectory == updated.FFmpegDirectory ? latest.FFmpegDirectory : updated.FFmpegDirectory,
            SceneSensitivity = original.SceneSensitivity == updated.SceneSensitivity ? latest.SceneSensitivity : updated.SceneSensitivity,
            SuppressCompletionNotification = original.SuppressCompletionNotification == updated.SuppressCompletionNotification
                ? latest.SuppressCompletionNotification
                : updated.SuppressCompletionNotification
        };
        Write(merged);
        return merged;
    });

    private static UserSettings LoadUnlocked()
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

    private static void Write(UserSettings settings)
    {
        var directory = Path.GetDirectoryName(SettingsPath) ?? throw new InvalidOperationException("Settings could not be saved.");
        Directory.CreateDirectory(directory);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void WithSettingsLock(Action action) => WithSettingsLock(() =>
    {
        action();
        return true;
    });

    private static T WithSettingsLock<T>(Func<T> action)
    {
        using var mutex = new Mutex(false, SettingsMutexName);
        var acquired = false;
        try
        {
            try
            {
                acquired = mutex.WaitOne(TimeSpan.FromSeconds(10));
            }
            catch (AbandonedMutexException)
            {
                acquired = true;
            }

            if (!acquired)
            {
                throw new IOException("RightClip could not access its settings because another worker is holding the settings lock.");
            }

            return action();
        }
        finally
        {
            if (acquired)
            {
                mutex.ReleaseMutex();
            }
        }
    }
}
