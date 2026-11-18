using RightClip.App;
using Xunit;

namespace RightClip.Tests;

public sealed class SettingsStoreTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();
    private readonly string? _previousSettingsPath = Environment.GetEnvironmentVariable("RIGHTCLIP_SETTINGS_PATH");

    public SettingsStoreTests()
    {
        Environment.SetEnvironmentVariable("RIGHTCLIP_SETTINGS_PATH", Path.Combine(_directory.Path, "settings.json"));
    }

    [Fact]
    public void ChangedFieldsMergeWithTheLatestSavedSettings()
    {
        var original = new UserSettings("original-tools", 40, false);
        SettingsStore.Save(original);

        SettingsStore.SaveChanges(original, original with { SuppressCompletionNotification = true });
        SettingsStore.SaveChanges(original, original with { SceneSensitivity = 75 });
        SettingsStore.SaveChanges(original, original with { FFmpegDirectory = "updated-tools" });

        var saved = SettingsStore.Load();
        Assert.Equal("updated-tools", saved.FFmpegDirectory);
        Assert.Equal(75, saved.SceneSensitivity);
        Assert.True(saved.SuppressCompletionNotification);
    }

    [Fact]
    public void ConcurrentWorkersPreserveIndependentChanges()
    {
        var original = new UserSettings("original-tools", 40, false);
        SettingsStore.Save(original);

        for (var iteration = 0; iteration < 20; iteration++)
        {
            Parallel.Invoke(
                () => SettingsStore.SaveChanges(original, original with { FFmpegDirectory = "updated-tools" }),
                () => SettingsStore.SaveChanges(original, original with { SceneSensitivity = 75 }),
                () => SettingsStore.SaveChanges(original, original with { SuppressCompletionNotification = true }));

            var saved = SettingsStore.Load();
            Assert.Equal("updated-tools", saved.FFmpegDirectory);
            Assert.Equal(75, saved.SceneSensitivity);
            Assert.True(saved.SuppressCompletionNotification);
        }
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("RIGHTCLIP_SETTINGS_PATH", _previousSettingsPath);
        _directory.Dispose();
    }
}
