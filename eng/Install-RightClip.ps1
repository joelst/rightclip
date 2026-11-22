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
# The payload copy below replaces RightClip.Identity.msix when the previous
# package lives in the install folder, so those bytes are saved first.
$menuSnapshotDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RightClip-menu-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $menuSnapshotDirectory | Out-Null
try {
    if (-not ('RightClip.MenuInstallNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace RightClip {
    public static class MenuInstallNative {
        [DllImport("kernelbase.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern int GetPackagePathByFullName2(string packageFullName, int packagePathType, ref uint pathLength, StringBuilder path);

        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    }
}
'@
    }

    $savedPackages = @()
    $packageIndex = 0
    foreach ($installedPackage in @(Get-AppxPackage -Name RightClip)) {
        if ($null -eq $installedPackage -or [string]::IsNullOrWhiteSpace($installedPackage.PackageFullName)) {
            continue
        }

        $resolver = Get-Command -Name Resolve-RightClipPackageExternalLocation -CommandType Function -ErrorAction SilentlyContinue
        if ($resolver) {
            $externalLocation = & $resolver -PackageFullName $installedPackage.PackageFullName
        }
        else {
            $length = [uint32]0
            $pathError = [RightClip.MenuInstallNative]::GetPackagePathByFullName2($installedPackage.PackageFullName, 5, [ref]$length, $null)
            if ($pathError -ne 122) {
                throw "The previous RightClip package external location could not be read ($pathError)."
            }

            $pathBuilder = New-Object System.Text.StringBuilder ([int]$length)
            $pathError = [RightClip.MenuInstallNative]::GetPackagePathByFullName2($installedPackage.PackageFullName, 5, [ref]$length, $pathBuilder)
            if ($pathError -ne 0) {
                throw "The previous RightClip package external location could not be read ($pathError)."
            }

            $externalLocation = $pathBuilder.ToString()
        }

        $externalLocation = $externalLocation.TrimEnd([char]0).TrimEnd('\')
        $sourcePackage = Join-Path $externalLocation 'RightClip.Identity.msix'
        if ([string]::IsNullOrWhiteSpace($externalLocation) -or -not (Test-Path -LiteralPath $sourcePackage)) {
            throw "The previous RightClip package is missing RightClip.Identity.msix in '$externalLocation'."
        }

        $savedPackagePath = Join-Path $menuSnapshotDirectory ("RightClip.Identity.{0}.msix" -f $packageIndex)
        Copy-Item -LiteralPath $sourcePackage -Destination $savedPackagePath
        $savedPackages += [pscustomobject]@{
            ExternalLocation = $externalLocation
            PackagePath = $savedPackagePath
        }
        $packageIndex++
    }

    $legacyRelativePaths = @()
    foreach ($suffix in @('01', '02', '03', '05')) {
        $legacyRelativePaths += "Software\Classes\CLSID\{6B22FDB5-38A2-4EF0-9D8A-2C4D24E210$suffix}"
    }
    foreach ($handler in @('Trim', 'Tracks', 'Details', 'RemoveMetadata')) {
        foreach ($extension in @('.mp4', '.mov', '.mkv', '.webm')) {
            $legacyRelativePaths += "Software\Classes\SystemFileAssociations\$extension\shellex\ContextMenuHandlers\RightClip.$handler"
        }
    }
    $legacyManifestLines = @()
    $legacyIndex = 0
    foreach ($relativePath in $legacyRelativePaths) {
        $legacyKey = "HKCU:\$relativePath"
        if (Test-Path -LiteralPath $legacyKey) {
            $legacyExport = Join-Path $menuSnapshotDirectory ("legacy-{0}.reg" -f $legacyIndex)
            & "$env:WINDIR\System32\reg.exe" export "HKCU\$relativePath" $legacyExport /y | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "The previous Explorer registration could not be read: $relativePath"
            }
            $legacyManifestLines += "1|$legacyIndex|$relativePath"
        }
        else {
            $legacyManifestLines += "0|$legacyIndex|$relativePath"
        }
        $legacyIndex++
    }
    $legacyManifest = Join-Path $menuSnapshotDirectory 'legacy.txt'
    [IO.File]::WriteAllLines($legacyManifest, [string[]]$legacyManifestLines)

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
    $packagesRemoved = $false
    $legacyRegistrationAttempted = $false
    try {
        if ($ModernMenu) {
            if (-not $production) {
                $certificate = Get-PfxCertificate -FilePath (Join-Path $installDirectory 'RightClip.Identity.cer')
                $certificatePath = Join-Path 'Cert:\LocalMachine\TrustedPeople' $certificate.Thumbprint
                if (-not (Test-Path -LiteralPath $certificatePath)) {
                    Import-Certificate -FilePath (Join-Path $installDirectory 'RightClip.Identity.cer') -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
                    Add-Content -LiteralPath (Join-Path $installDirectory 'RightClip.TrustedCertificates') -Value $certificate.Thumbprint
                }
            }
            $unregistration = Start-Process -FilePath "$env:WINDIR\System32\regsvr32.exe" -ArgumentList @('/s', '/u', "`"$shell`"") -Wait -PassThru -WindowStyle Hidden
            $legacyRegistrationAttempted = $true
            if ($unregistration.ExitCode -ne 0) {
                throw "Explorer command unregistration failed with exit code $($unregistration.ExitCode)."
            }
            Get-AppxPackage -Name RightClip | Remove-AppxPackage -ErrorAction Stop
            $packagesRemoved = $true
            Add-AppxPackage -ForceUpdateFromAnyVersion -Path (Join-Path $InstallDirectory 'RightClip.Identity.msix') -ExternalLocation $InstallDirectory
        }
        else {
            Get-AppxPackage -Name RightClip | Remove-AppxPackage -ErrorAction Stop
            $packagesRemoved = $true
            $registration = Start-Process -FilePath "$env:WINDIR\System32\regsvr32.exe" -ArgumentList @('/s', "`"$shell`"") -Wait -PassThru -WindowStyle Hidden
            if ($registration.ExitCode -ne 0) {
                $legacyRegistrationAttempted = $true
                throw "Explorer command registration failed with exit code $($registration.ExitCode)."
            }
        }
    }
    catch {
        $registrationError = $_
        try {
            if ($packagesRemoved) {
                Get-AppxPackage -Name RightClip | Remove-AppxPackage -ErrorAction Stop
                foreach ($savedPackage in $savedPackages) {
                    Add-AppxPackage -ForceUpdateFromAnyVersion -Path $savedPackage.PackagePath -ExternalLocation $savedPackage.ExternalLocation
                }
            }
            if ($legacyRegistrationAttempted) {
                $restoredLegacyKey = $false
                foreach ($legacyLine in [IO.File]::ReadAllLines($legacyManifest)) {
                    if ([string]::IsNullOrWhiteSpace($legacyLine)) {
                        continue
                    }
                    $legacyParts = $legacyLine.Split('|')
                    $legacyWasPresent = $legacyParts[0] -eq '1'
                    $legacyExportIndex = $legacyParts[1]
                    $legacyRelativePath = $legacyParts[2]
                    $legacyKey = "HKCU:\$legacyRelativePath"
                    if (Test-Path -LiteralPath $legacyKey) {
                        Remove-Item -LiteralPath $legacyKey -Recurse -Force
                        $restoredLegacyKey = $true
                    }
                    if ($legacyWasPresent) {
                        $legacyExport = Join-Path $menuSnapshotDirectory ("legacy-{0}.reg" -f $legacyExportIndex)
                        & "$env:WINDIR\System32\reg.exe" import $legacyExport | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "The previous Explorer registration could not be restored: $legacyRelativePath"
                        }
                        $restoredLegacyKey = $true
                    }
                }
                if ($restoredLegacyKey) {
                    [RightClip.MenuInstallNative]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
                }
            }
        }
        catch {
            throw "Restoring the previous RightClip menu failed. $($registrationError.Exception.Message) $($_.Exception.Message)"
        }
        throw $registrationError
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
}
finally {
    if (Test-Path -LiteralPath $menuSnapshotDirectory) {
        Remove-Item -LiteralPath $menuSnapshotDirectory -Recurse -Force
    }
}
