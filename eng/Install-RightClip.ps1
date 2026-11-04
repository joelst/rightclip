<#
.SYNOPSIS
Installs or registers a portable RightClip payload for the current user.
.DESCRIPTION
Use Setup for staged upgrades. Development modern-menu registration requires
explicit certificate consent and elevation; production registration does not.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$installDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\RightClip'),
    [switch]$modernMenu,
    [switch]$trustPackageCertificate
)

$ErrorActionPreference = 'Stop'
$payload = $PSScriptRoot
$uninstallScriptHashes = @{
    'Uninstall-RightClip.ps1' = '__RIGHTCLIP_UNINSTALL_SHA256__'
    'Assert-RightClipDirectory.ps1' = '__RIGHTCLIP_DIRECTORY_SHA256__'
}
foreach ($file in $uninstallScriptHashes.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $payload $file) -Algorithm SHA256).Hash -ne $uninstallScriptHashes[$file]) {
        throw "Uninstall script integrity verification failed: $($file). Use a complete published RightClip payload."
    }
}
. (Join-Path $PSScriptRoot 'Assert-RightClipDirectory.ps1')
$installDirectory = Assert-RightClipDirectory -Directory $installDirectory -Operation Install -PayloadDirectory $payload
if (-not (Test-Path (Join-Path $payload 'RightClip.exe')) -or
    -not (Test-Path (Join-Path $payload 'RightClip.Shell.dll')) -or
    -not (Test-Path (Join-Path $payload 'ffmpeg.exe')) -or
    -not (Test-Path (Join-Path $payload 'ffprobe.exe'))) {
    throw 'The RightClip package is incomplete.'
}

$production = Test-Path -LiteralPath (Join-Path $payload 'RightClip.Identity.Production')
if ($ModernMenu -and -not $production -and -not $TrustPackageCertificate) {
    throw 'Development modern-menu registration requires -TrustPackageCertificate and elevation.'
}
if ($ModernMenu -and -not $production) {
    $administrator = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $administrator.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run elevated to trust the development certificate, or use legacy registration.'
    }
}
New-Item -ItemType Directory -Force $installDirectory | Out-Null
if ([IO.Path]::GetFullPath($payload).TrimEnd('\') -ne $installDirectory) {
    Copy-Item (Join-Path $payload '*') $installDirectory -Recurse -Force
}

foreach ($file in $uninstallScriptHashes.Keys) {
    $path = Join-Path $installDirectory $file
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $uninstallScriptHashes[$file]) {
        throw "Uninstall script integrity verification failed: $($file). Use a complete published RightClip payload."
    }
}
foreach ($file in $uninstallScriptHashes.Keys) {
    Unblock-File -LiteralPath (Join-Path $installDirectory $file)
}

$shell = Join-Path $InstallDirectory 'RightClip.Shell.dll'
if ($ModernMenu) {
    if (-not $production) {
        $certificate = Get-PfxCertificate -FilePath (Join-Path $installDirectory 'RightClip.Identity.cer')
        $certificatePath = Join-Path 'Cert:\LocalMachine\TrustedPeople' $certificate.Thumbprint
        if (-not (Test-Path -LiteralPath $certificatePath)) {
            Import-Certificate -FilePath (Join-Path $installDirectory 'RightClip.Identity.cer') -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
            Add-Content -LiteralPath (Join-Path $installDirectory 'RightClip.TrustedCertificates') -Value $certificate.Thumbprint
        }
    }
    Add-AppxPackage -ForceUpdateFromAnyVersion -Path (Join-Path $InstallDirectory 'RightClip.Identity.msix') -ExternalLocation $InstallDirectory
}
else {
    $registration = Start-Process -FilePath "$env:WINDIR\System32\regsvr32.exe" -ArgumentList @('/s', "`"$shell`"") -Wait -PassThru -WindowStyle Hidden
    if ($registration.ExitCode -ne 0) {
        throw "Explorer command registration failed with exit code $($registration.ExitCode)."
    }
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Force $startMenu | Out-Null
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startMenu 'RightClip.lnk'))
$shortcut.TargetPath = Join-Path $InstallDirectory 'RightClip.exe'
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.Description = 'RightClip video tools'
$shortcut.IconLocation = "$($shortcut.TargetPath),0"
$shortcut.Save()

$powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$uninstallScript = Join-Path $InstallDirectory 'Uninstall-RightClip.ps1'
$uninstall = "`"$powerShell`" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File `"$uninstallScript`" -InstallDirectory `"$InstallDirectory`""
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClip'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'RightClip'
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $installDirectory 'RightClip.exe')).ProductVersion.Split('+')[0]
Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value $version
Set-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Joel Stidley'
Set-ItemProperty -Path $uninstallKey -Name DisplayIcon -Value "$($shortcut.TargetPath),0"
Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $InstallDirectory
Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value $uninstall
Set-ItemProperty -Path $uninstallKey -Name QuietUninstallString -Value $uninstall
Set-ItemProperty -Path $uninstallKey -Name NoModify -Value 1
Set-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1
$size = (Get-ChildItem $InstallDirectory -File -Recurse | Measure-Object Length -Sum).Sum / 1KB
Set-ItemProperty -Path $uninstallKey -Name EstimatedSize -Value ([Math]::Min([int]$size, [int]::MaxValue))

Write-Output "RightClip is installed in $($installDirectory)"
Write-Output 'No Windows restart is needed. Right-click a supported video to see the commands. If an upgrade still shows the old commands, restart Windows Explorer, not your computer.'
