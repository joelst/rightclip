<#
.SYNOPSIS
Applies a release tag to the project version and the Windows package version.
.DESCRIPTION
Accepts v1.0.0, v1.0.0-beta, or the short form v1.0-beta. The short form
uses patch 0. The Windows package identity stays a four-part numeric version.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Tag -notmatch '^v(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?$') {
    throw "Release tag '$Tag' is not a version. Use a tag such as v1.0.0-beta or v1.0-beta."
}

$patch = if ($Matches[3]) { $Matches[3] } else { '0' }
$suffix = if ($Matches[4]) { "-$($Matches[4])" } else { '' }
$version = "$($Matches[1]).$($Matches[2]).$patch$suffix"
$packageVersion = "$($Matches[1]).$($Matches[2]).$patch.0"
$propertiesPath = Join-Path $root 'Directory.Build.props'
[xml]$properties = Get-Content -LiteralPath $propertiesPath -Raw
$current = [string]$properties.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($current)) {
    throw 'Directory.Build.props does not contain a version.'
}
if ($current -eq $version) {
    Write-Output "Release version is already $version."
    return
}

$currentNumeric = ($current -split '[-+]', 2)[0]
$currentParts = $currentNumeric.Split('.')
if ($currentParts.Count -eq 2) {
    $currentNumeric += '.0'
}
elseif ($currentParts.Count -ne 3) {
    throw "The current version '$current' does not have a three-part numeric prefix."
}
$currentPackageVersion = "$currentNumeric.0"

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
Update-ReleaseToken (Join-Path $root 'packaging\AppxManifest.xml') "Version=`"$currentPackageVersion`"" "Version=`"$packageVersion`""
Update-ReleaseToken (Join-Path $root 'src\RightClip.App\app.manifest') "version=`"$currentPackageVersion`"" "version=`"$packageVersion`""
$separator = [char]0x00B7
Update-ReleaseToken (Join-Path $root 'src\RightClip.Setup\MainWindow.xaml') "Version $current $separator" "Version $version $separator"
Update-ReleaseToken (Join-Path $root 'eng\Test-Installer.ps1') "RightClip-$current-win-x64-Setup.exe" "RightClip-$version-win-x64-Setup.exe"
Update-ReleaseToken (Join-Path $root 'README.md') "RightClip-$current-win-x64" "RightClip-$version-win-x64"
Update-ReleaseToken (Join-Path $root 'docs\RELEASING.md') "``v$current``" "``v$version``"
Write-Output "Release version: $version"
