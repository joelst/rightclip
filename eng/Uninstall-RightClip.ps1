<#
.SYNOPSIS
Removes the RightClip installation containing this script.
.DESCRIPTION
Requires elevation only if this installation added a machine-trusted development
certificate. Refuses arbitrary targets and does not remove pre-existing trust.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$installDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Assert-RightClipDirectory.ps1')
$installDirectory = Assert-RightClipDirectory -Directory $installDirectory -Operation Uninstall -PayloadDirectory $PSScriptRoot
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClip'
if (Test-Path -LiteralPath $uninstallKey) {
    $registeredLocation = (Get-ItemProperty -LiteralPath $uninstallKey -Name InstallLocation).InstallLocation
    if ([IO.Path]::GetFullPath($registeredLocation).TrimEnd('\') -ne $installDirectory) {
        throw 'Another RightClip location owns the registered integration; uninstall that location first.'
    }
}
$trustFile = Join-Path $installDirectory 'RightClip.TrustedCertificates'
$ownedCertificates = @()
if (Test-Path -LiteralPath $trustFile) {
    $ownedCertificates = @(Get-Content -LiteralPath $trustFile | Select-Object -Unique)
    foreach ($thumbprint in $ownedCertificates) {
        if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
            throw 'The installation certificate ownership record is invalid.'
        }
        $certificatePath = Join-Path 'Cert:\LocalMachine\TrustedPeople' $thumbprint
        if (Test-Path -LiteralPath $certificatePath) {
            $administrator = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $administrator.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Run this uninstaller as administrator to remove the development certificate it installed.'
            }
        }
    }
}
$shell = Join-Path $InstallDirectory 'RightClip.Shell.dll'
if (Test-Path $shell) {
    $registration = Start-Process -FilePath "$env:WINDIR\System32\regsvr32.exe" -ArgumentList @('/s', '/u', "`"$shell`"") -Wait -PassThru -WindowStyle Hidden
    if ($registration.ExitCode -ne 0) {
        throw "Explorer command unregistration failed with exit code $($registration.ExitCode)."
    }
}

Get-AppxPackage -Name RightClip | Remove-AppxPackage -ErrorAction Stop
foreach ($thumbprint in $ownedCertificates) {
    $certificatePath = Join-Path 'Cert:\LocalMachine\TrustedPeople' $thumbprint
    if (Test-Path -LiteralPath $certificatePath) {
        Remove-Item -LiteralPath $certificatePath -Force
    }
}

$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\RightClip.lnk'
if (Test-Path -LiteralPath $shortcut) {
    Remove-Item -LiteralPath $shortcut -Force
}
if (Test-Path -LiteralPath $uninstallKey) {
    Remove-Item -LiteralPath $uninstallKey -Recurse -Force
}
try {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction Stop
    Write-Output 'RightClip is uninstalled.'
}
catch {
    throw "Integration was removed, but the installation folder could not be deleted: $($_.Exception.Message). Close RightClip and restart Explorer if files are locked, then remove $($installDirectory)."
}
