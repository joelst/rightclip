<#
.SYNOPSIS
Builds the self-contained app, native extension, identity package, and Setup.
.DESCRIPTION
Requires .NET 10, Visual Studio C++ x64 tools, and a Windows SDK.
DevelopmentSigning selects a development identity and skips Azure signing,
even when production signing environment variables are inherited.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$configuration = 'Release',
    [ValidateSet('win-x64')]
    [string]$runtime = 'win-x64',
    [switch]$developmentSigning,
    [ValidateNotNullOrEmpty()]
    [string]$outputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
[xml]$properties = Get-Content (Join-Path $root 'Directory.Build.props') -Raw
$version = $properties.Project.PropertyGroup.Version
$signingOptions = @{ AllowUnsignedDevelopment = $DevelopmentSigning }
$dist = [IO.Path]::GetFullPath($outputDirectory)
$stage = Join-Path $dist 'RightClip'
$package = Join-Path $dist "RightClip-$version-$Runtime.zip"
$setupPackage = Join-Path $dist "RightClip-$version-$Runtime-Setup.exe"
$setupPublish = Join-Path $dist 'setup'
if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
New-Item -ItemType Directory -Force $stage | Out-Null

$appManifest = Join-Path $root 'artifacts\identity\RightClip.app.manifest'
& (Join-Path $PSScriptRoot 'New-PackageIdentityMetadata.ps1') -OutputPath $appManifest -DevelopmentSigning:$DevelopmentSigning
& dotnet publish (Join-Path $root 'src\RightClip.App\RightClip.App.csproj') `
    --configuration $Configuration --runtime $Runtime --self-contained true `
    --output $stage -p:ApplicationManifest=$appManifest
if ($LASTEXITCODE -ne 0) {
    throw 'The application publish failed.'
}
& (Join-Path $PSScriptRoot 'Invoke-AzureTrustedSigning.ps1') -FilePath (Join-Path $stage 'RightClip.exe') @signingOptions
if ($LASTEXITCODE -ne 0) {
    throw 'The application signing failed.'
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio with C++ tools is required to build RightClip.Shell.'
}
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0) {
    throw 'Visual Studio toolchain discovery failed.'
}
if (-not $installation) {
    throw 'No Visual Studio C++ x64 toolchain was found.'
}
$msbuild = Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
& $msbuild (Join-Path $root 'src\RightClip.Shell\RightClip.Shell.vcxproj') /m `
    /p:Configuration=$Configuration /p:Platform=x64 /p:SolutionDir="$root\"
if ($LASTEXITCODE -ne 0) {
    throw 'The Explorer extension build failed.'
}
Copy-Item (Join-Path $root "artifacts\shell\$Configuration\RightClip.Shell.dll") $stage
& (Join-Path $PSScriptRoot 'Invoke-AzureTrustedSigning.ps1') -FilePath (Join-Path $stage 'RightClip.Shell.dll') @signingOptions
if ($LASTEXITCODE -ne 0) {
    throw 'The Explorer extension signing failed.'
}

& (Join-Path $PSScriptRoot 'Get-FFmpeg.ps1') -Destination $stage
& (Join-Path $PSScriptRoot 'New-IdentityPackage.ps1') -Stage $stage -DevelopmentSigning:$DevelopmentSigning
foreach ($file in @('LICENSE', 'NOTICE.md', 'README.md')) {
    Copy-Item (Join-Path $root $file) $stage
}
Copy-Item (Join-Path $PSScriptRoot 'Install-RightClip.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'Uninstall-RightClip.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'Assert-RightClipDirectory.ps1') $stage
$assetDirectory = Join-Path $stage 'assets'
New-Item -ItemType Directory -Force $assetDirectory | Out-Null
Copy-Item (Join-Path $root 'assets\RightClip.png') $assetDirectory
Copy-Item (Join-Path $root 'assets\Square150x150Logo.png') $assetDirectory
Copy-Item (Join-Path $root 'assets\Square44x44Logo.png') $assetDirectory
$dotnetRoot = Split-Path (Get-Command dotnet).Source -Parent
$licenseDirectory = Join-Path $stage 'licenses'
New-Item -ItemType Directory -Force $licenseDirectory | Out-Null
Copy-Item (Join-Path $dotnetRoot 'LICENSE.txt') (Join-Path $licenseDirectory 'dotnet-LICENSE.txt')
Copy-Item (Join-Path $dotnetRoot 'ThirdPartyNotices.txt') (Join-Path $licenseDirectory 'dotnet-ThirdPartyNotices.txt')

$unexpected = Get-ChildItem $stage -Filter 'av*.dll' -ErrorAction SilentlyContinue
if ($unexpected) {
    throw "Shared FFmpeg libraries were found in the application bundle: $($unexpected.Name -join ', ')"
}
foreach ($required in @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe', 'ffmpeg-source.tar.gz',
        'RightClip.Identity.msix', 'COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'COPYING.GPLv3', 'FFmpeg-Build.txt', 'Install-RightClip.ps1', 'Uninstall-RightClip.ps1',
        'Assert-RightClipDirectory.ps1', 'licenses\dotnet-LICENSE.txt', 'licenses\dotnet-ThirdPartyNotices.txt')) {
    if (-not (Test-Path (Join-Path $stage $required))) {
        throw "The release bundle is missing $required."
    }
}
$productionIdentity = Test-Path (Join-Path $stage 'RightClip.Identity.Production')
if ($productionIdentity -and -not (Test-Path (Join-Path $stage 'RightClip.Identity.cer'))) {
    Write-Verbose 'Production-signed identity package: no self-signed certificate trust is required.'
}
elseif (-not $productionIdentity -and (-not (Test-Path (Join-Path $stage 'RightClip.Identity.cer')) -or
        -not (Test-Path (Join-Path $stage 'RightClip.Identity.thumbprint')))) {
    throw 'The development identity package is missing its public certificate or thumbprint.'
}

if (Test-Path $package) {
    Remove-Item $package -Force
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $package -CompressionLevel Optimal

if (Test-Path $setupPublish) {
    Remove-Item $setupPublish -Recurse -Force
}
& dotnet publish (Join-Path $root 'src\RightClip.Setup\RightClip.Setup.csproj') `
    --configuration $Configuration --runtime $Runtime --self-contained true `
    --output $setupPublish -p:PayloadPath="$package" -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true
if ($LASTEXITCODE -ne 0) {
    throw 'The Setup executable publish failed.'
}
Copy-Item (Join-Path $setupPublish 'RightClip-Setup.exe') $setupPackage -Force
if (-not (Test-Path $setupPackage)) {
    throw 'The Setup executable was not created.'
}
& (Join-Path $PSScriptRoot 'Invoke-AzureTrustedSigning.ps1') -FilePath $setupPackage @signingOptions
if ($LASTEXITCODE -ne 0) {
    throw 'The Setup executable signing failed.'
}
Write-Output "Created $($package)"
Write-Output "Created $($setupPackage)"
