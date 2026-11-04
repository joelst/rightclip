using System.Runtime.Versioning;
using Microsoft.Win32;
using RightClip.Setup;
using Xunit;

namespace RightClip.Tests;

[SupportedOSPlatform("windows")]
[Collection("Installer logging")]
public sealed class InstallerRollbackTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();
    private readonly string _registryPath = $@"Software\RightClip.Tests\{Guid.NewGuid():N}";
    private readonly string? _previousLogDirectory = Environment.GetEnvironmentVariable("RIGHTCLIP_SETUP_LOG_DIRECTORY");

    public InstallerRollbackTests()
    {
        Environment.SetEnvironmentVariable("RIGHTCLIP_SETUP_LOG_DIRECTORY", _directory.Path);
    }

    [Fact]
    public void InstallationProgressLogsAndForwardsEachPhaseBeforeReturning()
    {
        InstallerLog.Start(new InstallerOptions(_directory.Path));
        var path = InstallerLog.LogPath;
        Assert.NotNull(path);
        var thread = Environment.CurrentManagedThreadId;
        var messages = new List<string>();
        var progress = new Installer.InstallationProgress(new CallbackProgress(message =>
        {
            Assert.Equal(thread, Environment.CurrentManagedThreadId);
            Assert.Contains(message, File.ReadAllText(path));
            messages.Add(message);
        }));

        progress.Report("Extracting RightClip");
        progress.Report("Installation complete");

        Assert.Equal(new[] { "Extracting RightClip", "Installation complete" }, messages);
        var log = File.ReadAllText(path);
        Assert.True(log.IndexOf(messages[0], StringComparison.Ordinal) < log.IndexOf(messages[1], StringComparison.Ordinal));
    }

    [Fact]
    public void ConcurrentLoggingRemainsBestEffortWhenWritesFail()
    {
        for (var attempt = 0; attempt < 16; attempt++)
        {
            InstallerLog.Start(new InstallerOptions(_directory.Path));
            var path = InstallerLog.LogPath;
            Assert.NotNull(path);
            using var blocked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

            Parallel.For(0, 1000, new ParallelOptions { MaxDegreeOfParallelism = 16 },
                index => InstallerLog.Info($"Concurrent phase {index}"));

            Assert.Null(InstallerLog.LogPath);
        }
    }

    private sealed class CallbackProgress(Action<string> callback) : IProgress<string>
    {
        public void Report(string value) => callback(value);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RegistrationRollbackRestoresExistingTreesAndRemovesNewTrees(bool existing)
    {
        if (existing)
        {
            using var key = Registry.CurrentUser.CreateSubKey(_registryPath);
            key.SetValue("", "previous handler");
            key.SetValue("Expandable", @"%LOCALAPPDATA%\RightClip", RegistryValueKind.ExpandString);
            using var server = key.CreateSubKey("InprocServer32");
            server.SetValue("", @"C:\Previous\RightClip.Shell.dll");
            server.SetValue("ThreadingModel", "Apartment");
        }

        var snapshot = Installer.ReadRegistryTree(_registryPath);
        using (var key = Registry.CurrentUser.CreateSubKey(_registryPath))
        {
            key.SetValue("", "replacement handler");
            key.SetValue("NewValue", 1);
            using var server = key.CreateSubKey("InprocServer32");
            server.SetValue("", @"C:\New\RightClip.Shell.dll");
            using var added = key.CreateSubKey("NewSubKey");
        }

        Installer.RestoreRegistryTree(_registryPath, snapshot);

        using var restored = Registry.CurrentUser.OpenSubKey(_registryPath);
        if (!existing)
        {
            Assert.Null(restored);
            return;
        }

        Assert.NotNull(restored);
        Assert.Equal("previous handler", restored.GetValue(""));
        Assert.Equal(@"%LOCALAPPDATA%\RightClip",
            restored.GetValue("Expandable", null, RegistryValueOptions.DoNotExpandEnvironmentNames));
        Assert.Equal(RegistryValueKind.ExpandString, restored.GetValueKind("Expandable"));
        Assert.Null(restored.GetValue("NewValue"));
        Assert.DoesNotContain("NewSubKey", restored.GetSubKeyNames());
        using var restoredServer = restored.OpenSubKey("InprocServer32");
        Assert.NotNull(restoredServer);
        Assert.Equal(@"C:\Previous\RightClip.Shell.dll", restoredServer.GetValue(""));
        Assert.Equal("Apartment", restoredServer.GetValue("ThreadingModel"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ShortcutRollbackRestoresOnlyThePreviousShortcut(bool existing)
    {
        var path = Path.Combine(_directory.Path, "RightClip.lnk");
        byte[] previous = [0, 1, 2, 255];
        if (existing)
        {
            File.WriteAllBytes(path, previous);
        }

        var rollback = Installer.CaptureFileRollback(path);
        File.WriteAllText(path, "replacement shortcut");
        rollback();

        if (existing)
        {
            Assert.Equal(previous, File.ReadAllBytes(path));
        }
        else
        {
            Assert.False(File.Exists(path));
        }
    }

    [Fact]
    public void PackageRollbackUsesCapturedPackageAndOriginalExternalLocation()
    {
        var package = _directory.File("RightClip.Identity.msix", "previous package");
        var snapshot = Installer.CaptureIdentityPackage(_directory.Path);
        File.WriteAllText(package, "replacement package");
        var removed = false;
        string? temporaryPackage = null;
        Installer.RollbackIdentityPackage(snapshot, () => removed = true, (path, location) =>
        {
            Assert.True(removed);
            Assert.Equal(_directory.Path, location);
            Assert.Equal("previous package", File.ReadAllText(path));
            Assert.NotEqual(package, path);
            temporaryPackage = path;
        });
        Assert.NotNull(temporaryPackage);
        Assert.False(File.Exists(temporaryPackage));
    }

    [Fact]
    public void PackageRollbackWithoutPreviousPackageOnlyRemovesNewRegistration()
    {
        var removed = false;
        Installer.RollbackIdentityPackage(null, () => removed = true,
            (_, _) => throw new InvalidOperationException("Unexpected registration."));
        Assert.True(removed);
    }

    [Fact]
    public void PackageRollbackCleansUpTemporaryPackageWhenRestorationFails()
    {
        _directory.File("RightClip.Identity.msix", "previous package");
        var snapshot = Installer.CaptureIdentityPackage(_directory.Path);
        string? temporaryPackage = null;
        Assert.Throws<InvalidOperationException>(() => Installer.RollbackIdentityPackage(snapshot, () => { }, (path, _) =>
        {
            temporaryPackage = path;
            throw new InvalidOperationException("Registration failed.");
        }));
        Assert.NotNull(temporaryPackage);
        Assert.False(File.Exists(temporaryPackage));
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("RIGHTCLIP_SETUP_LOG_DIRECTORY", _previousLogDirectory);
        Registry.CurrentUser.DeleteSubKeyTree(_registryPath, false);
        _directory.Dispose();
    }

    [CollectionDefinition("Installer logging", DisableParallelization = true)]
    public sealed class InstallerLoggingCollection;
}
