using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32;

namespace RightClip.Setup;

[SupportedOSPlatform("windows")]
public static class Installer
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClip";

    public static async Task InstallAsync(InstallerOptions options, IProgress<string>? progress = null)
    {
        InstallerLog.Start(options);
        try
        {
            await Task.Run(() => Install(options, new InstallationProgress(progress)));
            InstallerLog.Info("Installation completed successfully.");
        }
        catch (Exception exception)
        {
            InstallerLog.Error(exception);
            throw;
        }
    }

    internal sealed class InstallationProgress(IProgress<string>? progress) : IProgress<string>
    {
        public void Report(string message)
        {
            InstallerLog.Info(message);
            progress?.Report(message);
        }
    }

    public static bool IsProductionSignedPayload()
    {
        using var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("RightClip.Payload.zip");
        if (payload is null)
        {
            return false;
        }

        using var archive = new ZipArchive(payload, ZipArchiveMode.Read, false);
        return archive.GetEntry("RightClip.Identity.Production") is not null;
    }

    private static void Install(InstallerOptions options, IProgress<string>? progress)
    {
        var target = ValidateTarget(options.InstallDirectory);
        var parent = Path.GetDirectoryName(target) ?? throw new InvalidOperationException("Choose an install folder inside another directory.");
        var name = Path.GetFileName(target);
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, $".{name}.setup-{Guid.NewGuid():N}");
        var backup = Path.Combine(parent, $".{name}.backup-{Guid.NewGuid():N}");
        var hadExisting = Directory.Exists(target);
        var movedExisting = false;
        var installed = false;
        try
        {
            progress?.Report("Extracting RightClip");
            ExtractPayload(staging, progress);
            ValidatePayload(staging);
            var previousPackage = !options.Portable && options.RegisterExplorer && options.ModernMenu
                ? ReadIdentityPackage()
                : null;
            var previousTrust = Path.Combine(target, "RightClip.TrustedCertificates");
            if (hadExisting && File.Exists(previousTrust))
            {
                File.Copy(previousTrust, Path.Combine(staging, "RightClip.TrustedCertificates"));
            }

            if (hadExisting)
            {
                progress?.Report("Preparing the upgrade");
                MoveDirectoryWithRetry(target, backup);
                movedExisting = true;
            }

            try
            {
                MoveDirectoryWithRetry(staging, target);
                installed = true;
            }
            catch
            {
                if (movedExisting)
                {
                    MoveDirectoryWithRetry(backup, target);
                    movedExisting = false;
                }

                throw;
            }

            if (!options.Portable)
            {
                var rollbackActions = new List<Action>();
                try
                {
                    Integrate(options, target, progress, rollbackActions, previousPackage);
                }
                catch (Exception installationFailure)
                {
                    var failedTarget = target;
                    var previousTarget = backup;
                    if (movedExisting && Directory.Exists(target))
                    {
                        var failed = Path.Combine(parent, $".{name}.failed-{Guid.NewGuid():N}");
                        MoveDirectoryWithRetry(target, failed);
                        MoveDirectoryWithRetry(backup, target);
                        movedExisting = false;
                        failedTarget = failed;
                        previousTarget = target;
                    }

                    var rollbackFailures = new List<Exception>();
                    try
                    {
                        RevertNewCertificateTrust(failedTarget, previousTarget);
                    }
                    catch (Exception cleanupFailure)
                    {
                        rollbackFailures.Add(cleanupFailure);
                    }

                    for (var index = rollbackActions.Count - 1; index >= 0; index--)
                    {
                        try
                        {
                            rollbackActions[index]();
                        }
                        catch (Exception rollbackFailure)
                        {
                            rollbackFailures.Add(rollbackFailure);
                        }
                    }

                    if (rollbackFailures.Count > 0)
                    {
                        throw new AggregateException("Installation failed and rollback did not complete.",
                            installationFailure, new AggregateException(rollbackFailures));
                    }

                    throw;
                }
            }

            if (movedExisting)
            {
                TryDelete(backup);
            }

            progress?.Report("Installation complete");
        }
        finally
        {
            if (!installed || movedExisting)
            {
                TryDelete(staging);
            }
        }
    }

    private static void MoveDirectoryWithRetry(string source, string destination)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Directory.Move(source, destination);
                return;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                if (attempt == 4)
                {
                    throw;
                }

                InstallerLog.Info($"Directory move is temporarily locked (attempt {attempt + 1} of 5): {exception.Message}");
                System.Threading.Thread.Sleep(250 * (attempt + 1));
            }
        }
    }

    private static string ValidateTarget(string installDirectory)
    {
        if (string.IsNullOrWhiteSpace(installDirectory))
        {
            throw new InvalidOperationException("Choose an install location.");
        }

        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(installDirectory));
        var root = Path.GetPathRoot(target);
        if (root is null || string.Equals(target, Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("A drive root cannot be used as the install folder.");
        }

        if (File.Exists(target))
        {
            throw new InvalidOperationException("The install location is a file, not a folder.");
        }

        ValidateNormalDirectories(target);
        if (Directory.Exists(target))
        {
            var existingInstallation = File.Exists(Path.Combine(target, "RightClip.exe")) ||
                File.Exists(Path.Combine(target, "RightClip.Shell.dll")) ||
                File.Exists(Path.Combine(target, "RightClip.Core.dll")) ||
                File.Exists(Path.Combine(target, "Uninstall-RightClip.ps1"));
            if (Directory.EnumerateFileSystemEntries(target).Any() && !existingInstallation)
            {
                throw new InvalidOperationException("Choose an empty folder or an existing RightClip installation.");
            }
        }

        return target;
    }

    private static void ValidateNormalDirectories(string target)
    {
        for (DirectoryInfo? ancestor = new(target); ancestor is not null; ancestor = ancestor.Parent)
        {
            if (ancestor.Exists && (ancestor.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("Installation paths must not contain symbolic links or junctions.");
            }
        }

        if (!Directory.Exists(target))
        {
            return;
        }

        var pending = new Stack<string>();
        pending.Push(target);
        while (pending.Count > 0)
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(pending.Pop()))
            {
                var attributes = File.GetAttributes(entry);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException("The installation contains links or junctions; remove them before continuing.");
                }

                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(entry);
                }
            }
        }
    }

    private static void ExtractPayload(string staging, IProgress<string>? progress)
    {
        Directory.CreateDirectory(staging);
        using var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("RightClip.Payload.zip")
            ?? throw new InvalidOperationException("This Setup executable does not contain a RightClip installation payload.");
        using var archive = new ZipArchive(payload, ZipArchiveMode.Read, false);
        var claimed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var prefix = staging + Path.DirectorySeparatorChar;
        var extracted = 0;
        foreach (var entry in archive.Entries)
        {
            var relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
            foreach (var segment in relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                if (segment is "." or ".." || segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || segment.EndsWith(' '))
                {
                    throw new InvalidOperationException($"The Setup payload contains an unsafe path: {entry.FullName}");
                }
            }

            if (string.IsNullOrEmpty(entry.Name))
            {
                continue;
            }

            if (Path.IsPathRooted(relative))
            {
                throw new InvalidOperationException($"The Setup payload contains an absolute path: {entry.FullName}");
            }

            var destination = Path.GetFullPath(Path.Combine(staging, relative));
            if (!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || !claimed.Add(destination))
            {
                throw new InvalidOperationException($"The Setup payload contains an invalid or duplicate path: {entry.FullName}");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            entry.ExtractToFile(destination, false);
            extracted++;
            if (extracted % 50 == 0 || extracted == archive.Entries.Count)
            {
                progress?.Report($"Extracting files ({extracted} of {archive.Entries.Count})");
            }
        }
    }

    private static void ValidatePayload(string staging)
    {
        foreach (var required in new[] { "RightClip.exe", "RightClip.Shell.dll", "ffmpeg.exe", "ffprobe.exe",
                     "RightClip.Identity.msix", "Uninstall-RightClip.ps1", "Assert-RightClipDirectory.ps1", "LICENSE", "NOTICE.md", "ffmpeg-source.tar.gz", "COPYING.LGPLv2.1" })
        {
            if (!File.Exists(Path.Combine(staging, required)))
            {
                throw new InvalidOperationException($"The Setup payload is incomplete: {required} is missing.");
            }
        }

        if (!File.Exists(Path.Combine(staging, "RightClip.Identity.Production")) &&
            (!File.Exists(Path.Combine(staging, "RightClip.Identity.cer")) ||
             !File.Exists(Path.Combine(staging, "RightClip.Identity.thumbprint"))))
        {
            throw new InvalidOperationException("The development identity package is missing its public certificate or thumbprint.");
        }
    }

    private static void Integrate(InstallerOptions options, string target, IProgress<string>? progress,
        IList<Action> rollbackActions, IdentityPackageSnapshot? previousPackage)
    {
        if (options.RegisterExplorer && options.ModernMenu)
        {
            var productionSigned = File.Exists(Path.Combine(target, "RightClip.Identity.Production"));
            if (productionSigned)
            {
                VerifyProductionIdentity(target);
            }
            else if (!options.TrustPackageCertificate)
            {
                throw new InvalidOperationException("This development-signed RightClip menu requires permission to trust its public package certificate. Select the certificate consent option or use the legacy menu.");
            }

            if (!productionSigned)
            {
                progress?.Report("Trusting the development certificate in Local Computer > Trusted People");
                DevelopmentCertificateTrust.Trust(target, progress);
            }

            progress?.Report("Registering the modern RightClip menu");
            rollbackActions.Add(() => RollbackIdentityPackage(previousPackage,
                () => RunPowerShellCommand("$ErrorActionPreference = 'Stop'; Get-AppxPackage -Name RightClip | Remove-AppxPackage"),
                RegisterIdentityPackage));
            RegisterIdentityPackage(target);
        }
        else if (options.RegisterExplorer)
        {
            progress?.Report("Registering Explorer commands");
            rollbackActions.Add(() => SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero));
            foreach (var path in LegacyRegistrationPaths())
            {
                var snapshot = ReadRegistryTree(path);
                rollbackActions.Add(() => RestoreRegistryTree(path, snapshot));
            }

            RegisterShell(target, false);
        }

        if (options.CreateStartMenuShortcut)
        {
            progress?.Report("Creating the Start Menu shortcut");
            rollbackActions.Add(CaptureFileRollback(ShortcutPath));
            CreateShortcut(target);
        }

        var previousUninstallEntry = ReadRegistryTree(UninstallKey);
        rollbackActions.Add(() => RestoreRegistryTree(UninstallKey, previousUninstallEntry));
        progress?.Report("Adding the Windows uninstall entry");
        WriteUninstallEntry(target);
    }

    internal sealed record IdentityPackageSnapshot(string ExternalLocation, byte[] Package);

    private static IdentityPackageSnapshot? ReadIdentityPackage()
    {
        var fullName = RunPowerShellCommand("$ErrorActionPreference = 'Stop'; Get-AppxPackage -Name RightClip | Select-Object -First 1 -ExpandProperty PackageFullName").Trim();
        if (string.IsNullOrEmpty(fullName))
        {
            return null;
        }

        const int effectiveExternalPath = 5;
        uint length = 0;
        var error = GetPackagePathByFullName2(fullName, effectiveExternalPath, ref length, null);
        if (error != 122)
        {
            throw new Win32Exception(error, "The previous RightClip package external location could not be read.");
        }

        var path = new StringBuilder(checked((int)length));
        error = GetPackagePathByFullName2(fullName, effectiveExternalPath, ref length, path);
        if (error != 0)
        {
            throw new Win32Exception(error, "The previous RightClip package external location could not be read.");
        }

        return CaptureIdentityPackage(path.ToString());
    }

    internal static IdentityPackageSnapshot CaptureIdentityPackage(string externalLocation) =>
        new(externalLocation, File.ReadAllBytes(Path.Combine(externalLocation, "RightClip.Identity.msix")));

    internal static void RollbackIdentityPackage(IdentityPackageSnapshot? previous, Action remove,
        Action<string, string> register)
    {
        remove();
        if (previous is null)
        {
            return;
        }

        var directory = Directory.CreateTempSubdirectory("RightClip-rollback-");
        var package = Path.Combine(directory.FullName, "RightClip.Identity.msix");
        try
        {
            File.WriteAllBytes(package, previous.Package);
            register(package, previous.ExternalLocation);
        }
        finally
        {
            File.Delete(package);
            directory.Delete();
        }
    }

    private static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Microsoft", "Windows", "Start Menu", "Programs", "RightClip.lnk");

    internal static Action CaptureFileRollback(string path)
    {
        var previous = File.Exists(path) ? File.ReadAllBytes(path) : null;
        return () =>
        {
            if (previous is null)
            {
                File.Delete(path);
            }
            else
            {
                File.WriteAllBytes(path, previous);
            }
        };
    }

    private static IEnumerable<string> LegacyRegistrationPaths()
    {
        foreach (var (suffix, handler) in new[] { ("01", "Trim"), ("02", "Tracks"), ("03", "Details"), ("05", "RemoveMetadata") })
        {
            yield return $@"Software\Classes\CLSID\{{6B22FDB5-38A2-4EF0-9D8A-2C4D24E210{suffix}}}";
            foreach (var extension in new[] { ".mp4", ".mov", ".mkv", ".webm" })
            {
                yield return $@"Software\Classes\SystemFileAssociations\{extension}\shellex\ContextMenuHandlers\RightClip.{handler}";
            }
        }
    }

    internal sealed record RegistryTreeSnapshot(
        Dictionary<string, (object Value, RegistryValueKind Kind)> Values,
        Dictionary<string, RegistryTreeSnapshot> SubKeys);

    internal static RegistryTreeSnapshot? ReadRegistryTree(string path)
    {
        using var key = Registry.CurrentUser.OpenSubKey(path);
        return key is null ? null : ReadRegistryTree(key);
    }

    private static RegistryTreeSnapshot ReadRegistryTree(RegistryKey key)
    {
        var values = key.GetValueNames().ToDictionary(name => name,
            name => (key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames)!, key.GetValueKind(name)));
        var children = new Dictionary<string, RegistryTreeSnapshot>();
        foreach (var name in key.GetSubKeyNames())
        {
            using var child = key.OpenSubKey(name)
                ?? throw new InvalidOperationException($"The previous Explorer registration could not be read: {key.Name}\\{name}");
            children.Add(name, ReadRegistryTree(child));
        }

        return new RegistryTreeSnapshot(values, children);
    }

    internal static void RestoreRegistryTree(string path, RegistryTreeSnapshot? snapshot)
    {
        Registry.CurrentUser.DeleteSubKeyTree(path, false);
        if (snapshot is null)
        {
            return;
        }

        using var key = Registry.CurrentUser.CreateSubKey(path)
            ?? throw new InvalidOperationException($"The previous Explorer registration could not be restored: {path}");
        RestoreRegistryTree(key, snapshot);
    }

    private static void RestoreRegistryTree(RegistryKey key, RegistryTreeSnapshot snapshot)
    {
        foreach (var (name, value) in snapshot.Values)
        {
            key.SetValue(name, value.Value, value.Kind);
        }

        foreach (var (name, child) in snapshot.SubKeys)
        {
            using var childKey = key.CreateSubKey(name)
                ?? throw new InvalidOperationException($"The previous Explorer registration could not be restored: {key.Name}\\{name}");
            RestoreRegistryTree(childKey, child);
        }
    }

    [DllImport("kernelbase.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagePathByFullName2(string packageFullName, int packagePathType,
        ref uint pathLength, StringBuilder? path);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);

    private static void RevertNewCertificateTrust(string failedTarget, string restoredTarget)
    {
        var failedRecord = Path.Combine(failedTarget, "RightClip.TrustedCertificates");
        if (!File.Exists(failedRecord))
        {
            return;
        }

        var previousRecord = Path.Combine(restoredTarget, "RightClip.TrustedCertificates");
        var previous = File.Exists(previousRecord) ? File.ReadAllLines(previousRecord) : [];
        var added = File.ReadAllLines(failedRecord).Except(previous, StringComparer.OrdinalIgnoreCase).ToArray();
        if (added.Length == 0)
        {
            return;
        }

        foreach (var thumbprint in added)
        {
            DevelopmentCertificateTrust.Remove(thumbprint);
        }

        if (previous.Length > 0)
        {
            File.WriteAllLines(failedRecord, previous);
        }
        else
        {
            File.Delete(failedRecord);
        }
    }

    private static void VerifyProductionIdentity(string target)
    {
        var package = Path.Combine(target, "RightClip.Identity.msix");
        var status = RunPowerShellCommand($"(Get-AuthenticodeSignature -FilePath '{package.Replace("'", "''", StringComparison.Ordinal)}').Status").Trim();
        if (!string.Equals(status, "Valid", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"The production identity package signature is missing or untrusted (status: {status}).");
        }
    }

    private static void RegisterIdentityPackage(string target)
    {
        RegisterIdentityPackage(Path.Combine(target, "RightClip.Identity.msix"), target);
    }

    private static void RegisterIdentityPackage(string package, string target)
    {
        string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);
        RunPowerShellCommand($"$ErrorActionPreference = 'Stop'; Add-AppxPackage -ForceUpdateFromAnyVersion -Path '{Escape(package)}' -ExternalLocation '{Escape(target)}'");
    }

    private static string RunPowerShellCommand(string command)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-WindowStyle");
        startInfo.ArgumentList.Add("Hidden");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("RemoteSigned");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add(command);
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start modern menu registration.");
        var standardOutput = process.StandardOutput.ReadToEndAsync();
        var standardError = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        var output = standardOutput.GetAwaiter().GetResult() + standardError.GetAwaiter().GetResult();
        InstallerLog.Info(output.Trim());
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Windows package registration failed: {output.Trim()}");
        }

        return output;
    }

    private static void RegisterShell(string target, bool unregister)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "regsvr32.exe"),
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("/s");
        if (unregister)
        {
            startInfo.ArgumentList.Add("/u");
        }

        startInfo.ArgumentList.Add(Path.Combine(target, "RightClip.Shell.dll"));
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start Explorer command registration.");
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Explorer command registration failed with exit code {process.ExitCode}.");
        }
    }

    private static void CreateShortcut(string target)
    {
        var startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Microsoft", "Windows", "Start Menu", "Programs");
        Directory.CreateDirectory(startMenu);
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows shortcut support is unavailable.");
        var shell = Activator.CreateInstance(shellType);
        if (shell is null)
        {
            throw new InvalidOperationException("Windows shortcut support could not be started.");
        }

        object? shortcut = null;
        try
        {
            dynamic dispatcher = shell;
            shortcut = dispatcher.CreateShortcut(ShortcutPath);
            dynamic shortcutDispatcher = shortcut;
            shortcutDispatcher.TargetPath = Path.Combine(target, "RightClip.exe");
            shortcutDispatcher.WorkingDirectory = target;
            shortcutDispatcher.Description = "RightClip video tools";
            shortcutDispatcher.IconLocation = Path.Combine(target, "RightClip.exe") + ",0";
            shortcutDispatcher.Save();
        }
        finally
        {
            if (shortcut is not null)
            {
                Marshal.FinalReleaseComObject(shortcut);
            }

            Marshal.FinalReleaseComObject(shell);
        }
    }

    private static void WriteUninstallEntry(string target)
    {
        var executable = Path.Combine(target, "RightClip.exe");
        var script = Path.Combine(target, "Uninstall-RightClip.ps1");
        var powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var uninstall = $"\"{powerShell}\" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File \"{script}\" -InstallDirectory \"{target}\"";
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKey)
            ?? throw new InvalidOperationException("The Windows uninstall entry could not be created.");
        key.SetValue("DisplayName", "RightClip");
        key.SetValue("DisplayVersion", Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.4.0");
        key.SetValue("Publisher", "Joel Stidley");
        key.SetValue("DisplayIcon", executable + ",0");
        key.SetValue("InstallLocation", target);
        key.SetValue("UninstallString", uninstall);
        key.SetValue("QuietUninstallString", uninstall);
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        var size = Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length) / 1024;
        key.SetValue("EstimatedSize", (int)Math.Min(size, int.MaxValue), RegistryValueKind.DWord);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
