using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace RightClip.Setup;

public static class Installer
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClip";

    public static Task InstallAsync(InstallerOptions options, IProgress<string>? progress = null) =>
        Task.Run(() => Install(options, progress));

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
            var previousTrust = Path.Combine(target, "RightClip.TrustedCertificates");
            if (hadExisting && File.Exists(previousTrust))
            {
                File.Copy(previousTrust, Path.Combine(staging, "RightClip.TrustedCertificates"));
            }

            if (hadExisting)
            {
                progress?.Report("Preparing the upgrade");
                Directory.Move(target, backup);
                movedExisting = true;
            }

            try
            {
                Directory.Move(staging, target);
                installed = true;
            }
            catch
            {
                if (movedExisting)
                {
                    Directory.Move(backup, target);
                    movedExisting = false;
                }

                throw;
            }

            if (!options.Portable)
            {
                try
                {
                    Integrate(options, target, progress);
                }
                catch (Exception installationFailure)
                {
                    if (movedExisting && Directory.Exists(target))
                    {
                        var failed = Path.Combine(parent, $".{name}.failed-{Guid.NewGuid():N}");
                        Directory.Move(target, failed);
                        Directory.Move(backup, target);
                        movedExisting = false;
                        try
                        {
                            RevertNewCertificateTrust(failed, target);
                        }
                        catch (Exception cleanupFailure)
                        {
                            throw new AggregateException("The previous installation was restored, but development certificate cleanup failed.",
                                installationFailure, cleanupFailure);
                        }
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

        if (Directory.Exists(target))
        {
            if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("Choose a normal folder rather than a link or junction.");
            }

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

    private static void Integrate(InstallerOptions options, string target, IProgress<string>? progress)
    {
        if (options.RegisterExplorer && options.ModernMenu)
        {
            var productionSigned = File.Exists(Path.Combine(target, "RightClip.Identity.Production"));
            if (!productionSigned && !options.TrustPackageCertificate)
            {
                throw new InvalidOperationException("This development-signed RightClip menu requires permission to trust its public package certificate. Select the certificate consent option or use the legacy menu.");
            }

            if (!productionSigned)
            {
                progress?.Report("Trusting the development certificate in Local Computer > Trusted People");
                TrustPackageCertificate(target);
            }

            progress?.Report("Registering the modern RightClip menu");
            RegisterIdentityPackage(target);
        }
        else if (options.RegisterExplorer)
        {
            progress?.Report("Registering Explorer commands");
            RegisterShell(target, false);
        }

        if (options.CreateStartMenuShortcut)
        {
            progress?.Report("Creating the Start Menu shortcut");
            CreateShortcut(target);
        }

        progress?.Report("Adding the Windows uninstall entry");
        WriteUninstallEntry(target);
    }

    private static void TrustPackageCertificate(string target)
    {
        using var certificate = System.Security.Cryptography.X509Certificates.X509CertificateLoader.LoadCertificateFromFile(
            Path.Combine(target, "RightClip.Identity.cer"));
        try
        {
            using var store = new System.Security.Cryptography.X509Certificates.X509Store(
                System.Security.Cryptography.X509Certificates.StoreName.TrustedPeople,
                System.Security.Cryptography.X509Certificates.StoreLocation.LocalMachine,
                System.Security.Cryptography.X509Certificates.OpenFlags.ReadWrite);
            if (!store.Certificates.Contains(certificate))
            {
                store.Add(certificate);
                try
                {
                    File.AppendAllLines(Path.Combine(target, "RightClip.TrustedCertificates"), [certificate.Thumbprint]);
                }
                catch
                {
                    store.Remove(certificate);
                    throw;
                }
            }
        }
        catch (System.Security.Cryptography.CryptographicException exception)
        {
            throw new InvalidOperationException("Windows requires the development certificate in Local Computer > Trusted People. Run Setup as administrator or choose the legacy menu.", exception);
        }
    }

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

        using var store = new System.Security.Cryptography.X509Certificates.X509Store(
            System.Security.Cryptography.X509Certificates.StoreName.TrustedPeople,
            System.Security.Cryptography.X509Certificates.StoreLocation.LocalMachine,
            System.Security.Cryptography.X509Certificates.OpenFlags.ReadWrite);
        foreach (var thumbprint in added)
        {
            var certificates = store.Certificates.Find(
                System.Security.Cryptography.X509Certificates.X509FindType.FindByThumbprint, thumbprint, false);
            store.RemoveRange(certificates);
        }
    }

    private static void RegisterIdentityPackage(string target)
    {
        string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);
        var package = Path.Combine(target, "RightClip.Identity.msix");
        var command = $"$ErrorActionPreference = 'Stop'; Add-AppxPackage -ForceUpdateFromAnyVersion -Path '{Escape(package)}' -ExternalLocation '{Escape(target)}'";
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
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add(command);
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start modern menu registration.");
        var standardOutput = process.StandardOutput.ReadToEndAsync();
        var standardError = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        var output = standardOutput.GetAwaiter().GetResult() + standardError.GetAwaiter().GetResult();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Modern RightClip menu registration failed: {output.Trim()}");
        }
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
            shortcut = dispatcher.CreateShortcut(Path.Combine(startMenu, "RightClip.lnk"));
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
        var uninstall = $"\"{powerShell}\" -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{script}\" -InstallDirectory \"{target}\"";
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKey)
            ?? throw new InvalidOperationException("The Windows uninstall entry could not be created.");
        key.SetValue("DisplayName", "RightClip");
        key.SetValue("DisplayVersion", Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.2.0");
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
