<#
.SYNOPSIS
Applies a release tag to the project version and the Windows package version.
.DESCRIPTION
Accepts v1.0.0, v1.0.0-beta, or the short form v1.0-beta. The short form
uses patch 0. The Windows package identity is four numeric parts, each at
most 65535. A stable tag uses revision 100, a beta uses 1, a release
candidate uses 2, and any other prerelease uses 3.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Get-WindowsPackageRevision {
    param([string]$Prerelease)

    if ([string]::IsNullOrEmpty($Prerelease)) {
        return 100
    }

    $label = ($Prerelease -split '\.', 2)[0]
    if ($label -like 'beta*') { return 1 }
    if ($label -like 'rc*') { return 2 }
    return 3
}

function ConvertTo-UInt16Part {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    $number = 0L
    if (-not [long]::TryParse($Value, [ref]$number) -or $number -lt 0 -or $number -gt 65535) {
        throw "Windows package $Name '$Value' must be an integer from 0 through 65535."
    }

    return [int]$number
}

function Get-QuotedVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern
    )

    $text = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($text, $Pattern)
    if (-not $match.Success) {
        throw "Package version was not found in $Path."
    }

    return $match.Groups[1].Value
}

if ($Tag -notmatch '^v(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?$') {
    throw "Release tag '$Tag' is not a version. Use a tag such as v1.0.0-beta or v1.0-beta."
}

$patch = if ($Matches[3]) { $Matches[3] } else { '0' }
$prerelease = if ($Matches[4]) { $Matches[4] } else { '' }
$suffix = if ($prerelease) { "-$prerelease" } else { '' }
$version = "$($Matches[1]).$($Matches[2]).$patch$suffix"
$null = ConvertTo-UInt16Part -Value $Matches[1] -Name 'major'
$null = ConvertTo-UInt16Part -Value $Matches[2] -Name 'minor'
$null = ConvertTo-UInt16Part -Value $patch -Name 'patch'
$packageVersion = "$($Matches[1]).$($Matches[2]).$patch.$(Get-WindowsPackageRevision -Prerelease $prerelease)"
$propertiesPath = Join-Path $root 'Directory.Build.props'
[xml]$properties = Get-Content -LiteralPath $propertiesPath -Raw
$current = [string]$properties.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($current)) {
    throw 'Directory.Build.props does not contain a version.'
}

$appxPath = Join-Path $root 'packaging\AppxManifest.xml'
$assemblyPath = Join-Path $root 'src\RightClip.App\app.manifest'
$currentAppxVersion = Get-QuotedVersion -Path $appxPath -Pattern 'Identity Name="RightClip"[^>]*Version="([^"]+)"'
$currentAssemblyVersion = Get-QuotedVersion -Path $assemblyPath -Pattern 'assemblyIdentity version="([^"]+)"'
if ($current -eq $version -and $currentAppxVersion -eq $packageVersion -and $currentAssemblyVersion -eq $packageVersion) {
    Write-Output "Release version is already $version ($packageVersion)."
    return
}

function Update-ReleaseToken {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )
    if ($Old -eq $New -or -not $PSCmdlet.ShouldProcess($Path, 'Update release token')) {
        return
    }

    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.Contains($Old)) {
        if ($text.Contains($New)) {
            return
        }
        throw "Expected '$Old' in $Path."
    }

    [IO.File]::WriteAllText($Path, $text.Replace($Old, $New))
}

Update-ReleaseToken $propertiesPath "<Version>$current</Version>" "<Version>$version</Version>"
Update-ReleaseToken $appxPath "Version=`"$currentAppxVersion`"" "Version=`"$packageVersion`""
Update-ReleaseToken $assemblyPath "version=`"$currentAssemblyVersion`"" "version=`"$packageVersion`""
$separator = [char]0x00B7
Update-ReleaseToken (Join-Path $root 'src\RightClip.Setup\MainWindow.xaml') "Version $current $separator" "Version $version $separator"
Update-ReleaseToken (Join-Path $root 'eng\Test-Installer.ps1') "RightClip-$current-win-x64-Setup.exe" "RightClip-$version-win-x64-Setup.exe"
Update-ReleaseToken (Join-Path $root 'README.md') "RightClip-$current-win-x64" "RightClip-$version-win-x64"
Update-ReleaseToken (Join-Path $root 'docs\RELEASING.md') "``v$current``" "``v$version``"
Write-Output "Release version: $version"
