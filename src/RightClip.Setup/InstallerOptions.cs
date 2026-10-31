using System.IO;

namespace RightClip.Setup;

public sealed record InstallerOptions(
    string InstallDirectory,
    bool Silent = false,
    bool Portable = false,
    bool RegisterExplorer = true,
    bool CreateStartMenuShortcut = true,
    bool ModernMenu = true,
    bool TrustPackageCertificate = false)
{
    public static InstallerOptions Parse(IReadOnlyList<string> arguments)
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "RightClip");
        var silent = false;
        var portable = false;
        var explorer = true;
        var shortcut = true;
        var modern = true;
        var trust = false;
        for (var index = 0; index < arguments.Count; index++)
        {
            switch (arguments[index])
            {
                case "--silent":
                    silent = true;
                    break;
                case "--portable":
                    portable = true;
                    break;
                case "--no-explorer":
                    explorer = false;
                    break;
                case "--no-shortcut":
                    shortcut = false;
                    break;
                case "--modern-menu":
                    modern = true;
                    break;
                case "--legacy-menu":
                    modern = false;
                    break;
                case "--trust-package-certificate":
                    trust = true;
                    break;
                case "--install-dir" when index + 1 < arguments.Count:
                    directory = arguments[++index];
                    break;
                default:
                    throw new ArgumentException($"Unknown or incomplete Setup option: {arguments[index]}");
            }
        }

        return new InstallerOptions(directory, silent, portable, explorer, shortcut, modern, trust);
    }
}
