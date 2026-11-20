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
$recipeSource = Join-Path $root 'eng\ffmpeg'
$recipeStage = Join-Path $stage 'ffmpeg-recipe'
New-Item -ItemType Directory -Force -Path (Join-Path $recipeStage 'licenses') | Out-Null
foreach ($recipeFile in @('build.sh', 'sources.json', 'Dockerfile', 'bootstrap-wsl.sh')) {
    Copy-Item -LiteralPath (Join-Path $recipeSource $recipeFile) -Destination (Join-Path $recipeStage $recipeFile)
}
Copy-Item -LiteralPath (Join-Path $recipeSource 'licenses\winpthreads-COPYING') -Destination (Join-Path $recipeStage 'licenses\winpthreads-COPYING')
Add-Content -LiteralPath (Join-Path $stage 'FFmpeg-Build.txt') -Encoding utf8 -Value @(
    ''
    'Rebuild recipe: ffmpeg-recipe/build.sh, ffmpeg-recipe/sources.json, ffmpeg-recipe/Dockerfile, and ffmpeg-recipe/bootstrap-wsl.sh.'
    'Those files include the dependency build options and pkg-config edits. ffmpeg-recipe/licenses/winpthreads-COPYING is the notice for the statically linked winpthreads library.'
)
& (Join-Path $PSScriptRoot 'New-IdentityPackage.ps1') -Stage $stage -DevelopmentSigning:$DevelopmentSigning
foreach ($file in @('LICENSE', 'NOTICE.md', 'README.md', 'SUPPORT.md', 'SECURITY.md', 'CONTRIBUTING.md', 'AGENTS.md')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage
}
$docsStage = Join-Path $stage 'docs'
New-Item -ItemType Directory -Force $docsStage | Out-Null
foreach ($file in @('DEVELOPMENT.md', 'RELEASING.md', 'CODE_REVIEW.md')) {
    Copy-Item -LiteralPath (Join-Path $root "docs\$file") -Destination $docsStage
}
$imageStage = Join-Path $docsStage 'images'
New-Item -ItemType Directory -Force $imageStage | Out-Null
Copy-Item -Path (Join-Path $root 'docs\images\*.png') -Destination $imageStage
Copy-Item (Join-Path $PSScriptRoot 'Install-RightClip.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'Uninstall-RightClip.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'Assert-RightClipDirectory.ps1') $stage
$installerPath = Join-Path $stage 'Install-RightClip.ps1'
$installerContent = Get-Content -LiteralPath $installerPath -Raw
foreach ($entry in @{
    '__RIGHTCLIP_UNINSTALL_SHA256__' = 'Uninstall-RightClip.ps1'
    '__RIGHTCLIP_DIRECTORY_SHA256__' = 'Assert-RightClipDirectory.ps1'
}.GetEnumerator()) {
    if (-not $installerContent.Contains($entry.Key)) {
        throw "The installer is missing its script hash placeholder: $($entry.Key)"
    }
    $hash = (Get-FileHash -LiteralPath (Join-Path $stage $entry.Value) -Algorithm SHA256).Hash
    $installerContent = $installerContent.Replace($entry.Key, $hash)
}
Set-Content -LiteralPath $installerPath -Value $installerContent -Encoding utf8BOM
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
$winpthreadsNotice = Join-Path $licenseDirectory 'winpthreads-LICENSE'
if (-not (Test-Path -LiteralPath $winpthreadsNotice)) {
    Copy-Item -LiteralPath (Join-Path $root 'eng\ffmpeg\licenses\winpthreads-COPYING') -Destination $winpthreadsNotice
}

$unexpected = Get-ChildItem $stage -Filter 'av*.dll' -ErrorAction SilentlyContinue
if ($unexpected) {
    throw "Shared FFmpeg libraries were found in the application bundle: $($unexpected.Name -join ', ')"
}
$stageRoot = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
foreach ($document in @('README.md', 'NOTICE.md', 'SUPPORT.md', 'SECURITY.md', 'CONTRIBUTING.md', 'AGENTS.md',
        'docs\DEVELOPMENT.md', 'docs\RELEASING.md', 'docs\CODE_REVIEW.md')) {
    $text = Get-Content -LiteralPath (Join-Path $stage $document) -Raw
    $directory = Split-Path -Path $document -Parent
    foreach ($match in [regex]::Matches($text, '(?:\[[^\]]+\]\(|src=["''])([^"''#\s)]+)')) {
        $target = $match.Groups[1].Value
        if ($target.StartsWith('http://') -or $target.StartsWith('https://') -or $target.StartsWith('mailto:')) {
            continue
        }
        $relative = ($target -replace '/', '\').TrimStart('\')
        $base = if ([string]::IsNullOrEmpty($directory)) { $stage } else { Join-Path $stage $directory }
        $resolved = [IO.Path]::GetFullPath((Join-Path $base $relative))
        if (-not $resolved.StartsWith($stageRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "The release bundle is missing $target, linked from $document."
        }
    }
}
foreach ($required in @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe', 'ffmpeg-source.tar.gz',
        'README.md', 'SUPPORT.md', 'SECURITY.md', 'CONTRIBUTING.md', 'AGENTS.md',
        'docs\DEVELOPMENT.md', 'docs\RELEASING.md', 'docs\CODE_REVIEW.md', 'docs\images\trim-timeline.png',
        'zlib-1.4.tar.gz', 'openh264-2.7.0.tar.gz', 'kvazaar-2.3.2.tar.gz', 'libvpx-1.17.0.tar.gz', 'libaom-3.15.3.tar.gz',
        'RightClip.Identity.msix', 'COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'COPYING.GPLv3', 'FFmpeg-Build.txt', 'Install-RightClip.ps1', 'Uninstall-RightClip.ps1',
        'Assert-RightClipDirectory.ps1', 'licenses\dotnet-LICENSE.txt', 'licenses\dotnet-ThirdPartyNotices.txt',
        'licenses\zlib-LICENSE', 'licenses\openh264-LICENSE', 'licenses\kvazaar-LICENSE', 'licenses\libvpx-LICENSE', 'licenses\libvpx-PATENTS',
        'licenses\libaom-LICENSE', 'licenses\libaom-PATENTS', 'licenses\winpthreads-LICENSE',
        'ffmpeg-recipe\build.sh', 'ffmpeg-recipe\sources.json', 'ffmpeg-recipe\Dockerfile', 'ffmpeg-recipe\bootstrap-wsl.sh',
        'ffmpeg-recipe\licenses\winpthreads-COPYING')) {
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
