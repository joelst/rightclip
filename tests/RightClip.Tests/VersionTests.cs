using System.Xml.Linq;
using Xunit;

namespace RightClip.Tests;

public sealed class VersionTests
{
    [Fact]
    public void InstallationArtifactsUseTheProjectVersion()
    {
        var root = RepositoryRoot();
        var version = XDocument.Load(Path.Combine(root, "Directory.Build.props")).Root?
            .Element("PropertyGroup")?.Element("Version")?.Value;
        Assert.False(string.IsNullOrWhiteSpace(version));
        var packageVersion = version + ".0";

        var package = XDocument.Load(Path.Combine(root, "packaging", "AppxManifest.xml"));
        Assert.Equal(packageVersion, package.Root?.Elements().First(element => element.Name.LocalName == "Identity").Attribute("Version")?.Value);

        var appManifest = XDocument.Load(Path.Combine(root, "src", "RightClip.App", "app.manifest"));
        Assert.Equal(packageVersion, appManifest.Root?.Elements().First(element => element.Name.LocalName == "assemblyIdentity").Attribute("version")?.Value);

        Assert.Contains($"Version {version} · Windows x64", File.ReadAllText(Path.Combine(root, "src", "RightClip.Setup", "MainWindow.xaml")));
        Assert.Contains($"RightClip-{version}-win-x64-Setup.exe", File.ReadAllText(Path.Combine(root, "eng", "Test-Installer.ps1")));
        Assert.Contains($"RightClip-{version}-win-x64-Setup.exe", File.ReadAllText(Path.Combine(root, "README.md")));
        Assert.Contains($"v{version}", File.ReadAllText(Path.Combine(root, "docs", "RELEASING.md")));
    }

    [Fact]
    public void LoadingIndicatorUsesTheExplicitLoadingState()
    {
        var root = RepositoryRoot();
        var window = File.ReadAllText(Path.Combine(root, "src", "RightClip.App", "MainWindow.xaml"));
        var viewModel = File.ReadAllText(Path.Combine(root, "src", "RightClip.App", "MainViewModel.cs"));
        Assert.Contains("LoadingIndicatorText", window);
        Assert.Contains("Visibility=\"{Binding IsLoading", window);
        Assert.Contains("BeginMediaLoad();", viewModel);
        Assert.Contains("EndMediaLoad();", viewModel);
    }

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Directory.Build.props")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException("Could not locate the RightClip repository root.");
    }
}
