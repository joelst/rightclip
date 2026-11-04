using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.Versioning;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;

namespace RightClip.Setup;

internal enum DevelopmentCertificateOperation
{
    Trust,
    Remove
}

[SupportedOSPlatform("windows")]
internal static class DevelopmentCertificateTrust
{
    private const string TrustArgument = "--trust-development-certificate";
    private const string RemoveArgument = "--remove-development-certificate";

    public static bool TryRunHelper(IReadOnlyList<string> arguments, out int exitCode)
    {
        exitCode = 0;
        if (arguments.Count == 0 || arguments[0] is not (TrustArgument or RemoveArgument))
        {
            return false;
        }

        if (arguments.Count != 2)
        {
            throw new ArgumentException("A development certificate operation requires its expected certificate thumbprint.");
        }

        using var certificate = ReadOwnCertificate();
        if (!string.Equals(arguments[1], certificate.Thumbprint, StringComparison.OrdinalIgnoreCase))
        {
            exitCode = 3;
        }
        else if (!IsAdministrator())
        {
            exitCode = 4;
        }
        else
        {
            var operation = arguments[0] == TrustArgument ? DevelopmentCertificateOperation.Trust : DevelopmentCertificateOperation.Remove;
            exitCode = ChangeStore(certificate, operation) ? 0 : 2;
        }

        return true;
    }

    public static void Trust(string target, IProgress<string>? progress)
    {
        using var certificate = ReadOwnCertificate();
        RecordOwnership(Path.Combine(target, "RightClip.TrustedCertificates"), certificate.Thumbprint,
            () => IsTrusted(certificate),
            () => ChangeTrust(certificate, DevelopmentCertificateOperation.Trust, progress),
            () => ChangeTrust(certificate, DevelopmentCertificateOperation.Remove, progress));
    }

    public static void Remove(string thumbprint)
    {
        using var certificate = ReadOwnCertificate();
        if (!string.Equals(thumbprint, certificate.Thumbprint, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Setup cannot remove a certificate that is not included in its own payload.");
        }

        if (IsTrusted(certificate))
        {
            ChangeTrust(certificate, DevelopmentCertificateOperation.Remove, null);
        }
    }

    internal static void RecordOwnership(string recordPath, string thumbprint, Func<bool> isTrusted,
        Func<bool> addCertificate, Action removeCertificate)
    {
        if (isTrusted())
        {
            return;
        }

        var previous = File.Exists(recordPath) ? File.ReadAllBytes(recordPath) : null;
        if (!addCertificate())
        {
            return;
        }

        try
        {
            File.AppendAllLines(recordPath, [thumbprint]);
        }
        catch (Exception recordingFailure)
        {
            try
            {
                removeCertificate();
                if (previous is not null)
                {
                    File.WriteAllBytes(recordPath, previous);
                }
                else if (File.Exists(recordPath))
                {
                    File.Delete(recordPath);
                }
            }
            catch (Exception cleanupFailure)
            {
                throw new AggregateException("The development certificate was trusted, but recording its ownership and cleaning it up failed.",
                    recordingFailure, cleanupFailure);
            }

            throw;
        }
    }

    internal static bool RunElevated(string executable, DevelopmentCertificateOperation operation, string thumbprint,
        Func<ProcessStartInfo, int> runProcess)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = true,
            Verb = "runas"
        };
        startInfo.ArgumentList.Add(operation switch
        {
            DevelopmentCertificateOperation.Trust => TrustArgument,
            DevelopmentCertificateOperation.Remove => RemoveArgument,
            _ => throw new ArgumentOutOfRangeException(nameof(operation))
        });
        startInfo.ArgumentList.Add(thumbprint);
        int exitCode;
        try
        {
            exitCode = runProcess(startInfo);
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            throw new OperationCanceledException("Administrator approval was cancelled. Click Install to retry, or choose the legacy menu.", exception);
        }

        return exitCode switch
        {
            0 => true,
            2 => false,
            3 => throw new InvalidOperationException("The elevated Setup certificate does not match this installer. Run the same Setup executable again."),
            4 => throw new InvalidOperationException("Windows did not grant administrator rights for the development certificate operation."),
            _ => throw new InvalidOperationException($"The elevated development certificate operation failed with exit code {exitCode}.")
        };
    }

    private static bool ChangeTrust(X509Certificate2 certificate, DevelopmentCertificateOperation operation, IProgress<string>? progress)
    {
        if (IsAdministrator())
        {
            return ChangeStore(certificate, operation);
        }

        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("The Setup executable path is unavailable.");
        if (string.Equals(Path.GetFileNameWithoutExtension(executable), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Run the published Setup executable directly to approve development certificate trust.");
        }

        progress?.Report("Waiting for Windows administrator approval for the development certificate");
        return RunElevated(executable, operation, certificate.Thumbprint, startInfo =>
        {
            using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not request administrator approval.");
            process.WaitForExit();
            return process.ExitCode;
        });
    }

    private static X509Certificate2 ReadOwnCertificate()
    {
        using var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("RightClip.Payload.zip")
            ?? throw new InvalidOperationException("This Setup executable does not contain an installation payload.");
        using var archive = new ZipArchive(payload, ZipArchiveMode.Read, false);
        if (archive.GetEntry("RightClip.Identity.Production") is not null)
        {
            throw new InvalidOperationException("Production packages do not require development certificate trust.");
        }

        var entry = archive.GetEntry("RightClip.Identity.cer")
            ?? throw new InvalidOperationException("The development certificate is missing from the Setup payload.");
        using var stream = entry.Open();
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return X509CertificateLoader.LoadCertificate(bytes.ToArray());
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static bool IsTrusted(X509Certificate2 certificate)
    {
        using var store = new X509Store(StoreName.TrustedPeople, StoreLocation.LocalMachine, OpenFlags.ReadOnly);
        return store.Certificates.Contains(certificate);
    }

    private static bool ChangeStore(X509Certificate2 certificate, DevelopmentCertificateOperation operation)
    {
        using var store = new X509Store(StoreName.TrustedPeople, StoreLocation.LocalMachine, OpenFlags.ReadWrite);
        var exists = store.Certificates.Contains(certificate);
        if (operation == DevelopmentCertificateOperation.Trust)
        {
            if (exists)
            {
                return false;
            }

            store.Add(certificate);
        }
        else
        {
            if (!exists)
            {
                return false;
            }

            store.Remove(certificate);
        }

        return true;
    }
}
