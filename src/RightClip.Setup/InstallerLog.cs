using System.IO;

namespace RightClip.Setup;

public static class InstallerLog
{
    private static readonly object Sync = new();

    public static string? LogPath { get; private set; }

    public static void Start(InstallerOptions options)
    {
        LogPath = null;
        try
        {
            var directory = Environment.GetEnvironmentVariable("RIGHTCLIP_SETUP_LOG_DIRECTORY") ??
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RightClip", "Logs");
            Directory.CreateDirectory(directory);
            LogPath = Path.Combine(directory, $"setup-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.log");
            Info($"RightClip Setup started. Target: {options.InstallDirectory}; portable: {options.Portable}; modern menu: {options.ModernMenu}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            LogPath = null;
        }
    }

    public static void Info(string message)
    {
        var path = LogPath;
        if (path is null)
        {
            return;
        }

        try
        {
            lock (Sync)
            {
                File.AppendAllText(path, $"[{DateTime.Now:O}] {message}{Environment.NewLine}");
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            LogPath = null;
        }
    }

    public static void Error(Exception exception) => Info(exception.ToString());
}
