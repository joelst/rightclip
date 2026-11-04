using System.ComponentModel;
using System.Runtime.Versioning;
using RightClip.Setup;
using Xunit;

namespace RightClip.Tests;

[SupportedOSPlatform("windows")]
public sealed class InstallerElevationTests : IDisposable
{
    private readonly TemporaryDirectory _directory = new();

    [Fact]
    public void ExistingTrustDoesNotElevateOrClaimOwnership()
    {
        var record = _directory.File("trust.txt", "previous certificate");
        DevelopmentCertificateTrust.RecordOwnership(record, "new certificate", () => true,
            () => throw new InvalidOperationException("Unexpected elevation."),
            () => throw new InvalidOperationException("Unexpected removal."));
        Assert.Equal("previous certificate", File.ReadAllText(record));
    }

    [Fact]
    public void TrustRequestsOnlyTheCertificateHelperAndRecordsAddedTrust()
    {
        var record = _directory.File("trust.txt", "previous certificate" + Environment.NewLine);
        DevelopmentCertificateTrust.RecordOwnership(record, "new certificate", () => false,
            () => DevelopmentCertificateTrust.RunElevated(_directory.File("RightClip Setup.exe"),
                DevelopmentCertificateOperation.Trust, "new certificate", startInfo =>
                {
                    Assert.True(startInfo.UseShellExecute);
                    Assert.Equal("runas", startInfo.Verb);
                    Assert.Equal(new[] { "--trust-development-certificate", "new certificate" }, startInfo.ArgumentList);
                    return 0;
                }),
            () => throw new InvalidOperationException("Unexpected removal."));
        Assert.Equal(new[] { "previous certificate", "new certificate" }, File.ReadAllLines(record));
    }

    [Fact]
    public void DeniedUacKeepsOwnershipUnchanged()
    {
        var record = _directory.File("trust.txt", "previous certificate");
        Assert.Throws<OperationCanceledException>(() =>
            DevelopmentCertificateTrust.RecordOwnership(record, "new certificate", () => false,
                () => DevelopmentCertificateTrust.RunElevated("RightClip-Setup.exe", DevelopmentCertificateOperation.Trust,
                    "new certificate", _ => throw new Win32Exception(1223)),
                () => throw new InvalidOperationException("Unexpected removal.")));
        Assert.Equal("previous certificate", File.ReadAllText(record));
    }

    [Fact]
    public void TrustAddedByAnotherInstallerIsNotClaimed()
    {
        var record = Path.Combine(_directory.Path, "trust.txt");
        DevelopmentCertificateTrust.RecordOwnership(record, "new certificate", () => false,
            () => DevelopmentCertificateTrust.RunElevated("RightClip-Setup.exe", DevelopmentCertificateOperation.Trust,
                "new certificate", _ => 2),
            () => throw new InvalidOperationException("Unexpected removal."));
        Assert.False(File.Exists(record));
    }

    [Fact]
    public void FailedOwnershipRecordingRollsBackTheAddedCertificate()
    {
        var removed = false;
        Assert.Throws<UnauthorizedAccessException>(() =>
            DevelopmentCertificateTrust.RecordOwnership(_directory.Path, "new certificate", () => false,
                () => true, () =>
                {
                    DevelopmentCertificateTrust.RunElevated("RightClip-Setup.exe", DevelopmentCertificateOperation.Remove,
                        "new certificate", startInfo =>
                        {
                            Assert.Equal("--remove-development-certificate", startInfo.ArgumentList[0]);
                            return 0;
                        });
                    removed = true;
                }));
        Assert.True(removed);
        Assert.True(Directory.Exists(_directory.Path));
    }

    public void Dispose() => _directory.Dispose();
}
