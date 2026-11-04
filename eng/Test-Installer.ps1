<#
.SYNOPSIS
Tests portable Setup installation, upgrades, and packaged UI/native behavior.
.DESCRIPTION
Requires a published Setup executable and an interactive Windows desktop.
Does not register Explorer commands, uninstall entries, or machine certificates.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$setupPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip-0.3.0-win-x64-Setup.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'TestResults\installer-smoke'
$unsafe = Join-Path $root 'TestResults\installer-unsafe'
$damaged = Join-Path $root 'TestResults\installer-damaged'
foreach ($directory in @($work, $unsafe, $damaged)) {
    if (Test-Path $directory) {
        Remove-Item $directory -Recurse -Force
    }
}

. (Join-Path $PSScriptRoot 'Assert-RightClipDirectory.ps1')
$safetyWork = Join-Path $root 'TestResults\directory-safety'
if (Test-Path -LiteralPath $safetyWork) {
    Remove-Item -LiteralPath $safetyWork -Recurse -Force
}
New-Item -ItemType Directory -Force $safetyWork | Out-Null
Set-Content -LiteralPath (Join-Path $safetyWork 'sentinel.txt') -Value 'unrelated user file'
$sentinelHash = (Get-FileHash (Join-Path $safetyWork 'sentinel.txt') -Algorithm SHA256).Hash
foreach ($target in @([IO.Path]::GetPathRoot($root), $safetyWork)) {
    $rejected = $false
    try {
        Assert-RightClipDirectory -Directory $target -Operation Install -PayloadDirectory $PSScriptRoot | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Portable installer validation accepted an unsafe directory: $($target)"
    }
}
Set-Content -LiteralPath (Join-Path $safetyWork 'RightClip.Shell.dll') -Value 'directory identification fixture'
Set-Content -LiteralPath (Join-Path $safetyWork 'Uninstall-RightClip.ps1') -Value 'directory identification fixture'
$rejected = $false
try {
    Assert-RightClipDirectory -Directory $safetyWork -Operation Uninstall -PayloadDirectory $PSScriptRoot | Out-Null
}
catch {
    $rejected = $true
}
if (-not $rejected) {
    throw 'The uninstaller accepted a target outside its own installation.'
}
$validated = Assert-RightClipDirectory -Directory $safetyWork -Operation Uninstall -PayloadDirectory $safetyWork
if ($validated -ne $safetyWork -or (Get-FileHash (Join-Path $safetyWork 'sentinel.txt') -Algorithm SHA256).Hash -ne $sentinelHash) {
    throw 'Directory safety validation changed the sentinel or normalized the target incorrectly.'
}

for ($attempt = 1; $attempt -le 2; $attempt++) {
    $process = Start-Process -FilePath $SetupPath -ArgumentList @('--silent', '--portable', '--install-dir', "`"$work`"") -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "Setup failed with exit code $($process.ExitCode) on pass $attempt."
    }
}

$required = @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe', 'Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1',
    'RightClip.Identity.msix', 'LICENSE', 'NOTICE.md', 'ffmpeg-source.tar.gz', 'COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'COPYING.GPLv3',
    'licenses\dotnet-LICENSE.txt', 'licenses\dotnet-ThirdPartyNotices.txt')
if (Test-Path (Join-Path $work 'RightClip.Identity.Production')) {
    $required += 'RightClip.Identity.Production'
}
else {
    $required += @('RightClip.Identity.cer', 'RightClip.Identity.thumbprint')
}
foreach ($required in $required) {
    if (-not (Test-Path (Join-Path $work $required))) {
        throw "The installed payload is missing $required."
    }
}

New-Item -ItemType Directory -Force $damaged | Out-Null
Set-Content -Path (Join-Path $damaged 'RightClip.Shell.dll') -Value 'damaged previous installation'
$process = Start-Process -FilePath $SetupPath -ArgumentList @('--silent', '--portable', '--install-dir', "`"$damaged`"") -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0 -or -not (Test-Path (Join-Path $damaged 'RightClip.exe'))) {
    throw "Setup could not repair a damaged RightClip installation (exit $($process.ExitCode))."
}

New-Item -ItemType Directory -Force $unsafe | Out-Null
Set-Content -Path (Join-Path $unsafe 'user-file.txt') -Value 'do not move or delete'
$sentinelHash = (Get-FileHash (Join-Path $unsafe 'user-file.txt') -Algorithm SHA256).Hash
$process = Start-Process -FilePath $SetupPath -ArgumentList @('--silent', '--portable', '--install-dir', "`"$unsafe`"") -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -eq 0) {
    throw 'Setup unexpectedly accepted a non-empty directory that is not a RightClip installation.'
}
if ((Get-FileHash (Join-Path $unsafe 'user-file.txt') -Algorithm SHA256).Hash -ne $sentinelHash) {
    throw 'Setup changed the unsafe-directory sentinel.'
}

Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($SetupPath)
if ($null -eq $icon -or $icon.Width -lt 32 -or $icon.Height -lt 32) {
    throw 'Setup does not contain the RightClip application icon.'
}
$bitmap = $icon.ToBitmap()
$bitmap.Save((Join-Path $root 'TestResults\setup-icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
$icon.Dispose()

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$guiWork = Join-Path $root 'TestResults\installer-ui'
if (Test-Path $guiWork) {
    Remove-Item $guiWork -Recurse -Force
}
$gui = Start-Process -FilePath $SetupPath -ArgumentList @('--portable', '--install-dir', "`"$guiWork`"") -PassThru
try {
    $windowCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RightClip Setup'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $gui.Id))
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $windowCondition)
        if ($window) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $window) {
        throw 'The Setup window did not open.'
    }
    $installCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Install'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
    $installButton = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $installCondition)
    if (-not $installButton -or -not $installButton.Current.IsEnabled) {
        throw 'The Setup Install button was not ready.'
    }
    $installButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    $closeCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Close'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Button'))
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $closeButton = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $closeCondition)
        if ($closeButton -and $closeButton.Current.IsEnabled) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $closeButton -or -not $closeButton.Current.IsEnabled) {
        throw 'Setup did not reach its completed state.'
    }
    if (-not (Test-Path (Join-Path $guiWork 'RightClip.exe'))) {
        throw 'The Setup GUI did not honor portable installation mode.'
    }

    $windowBounds = $window.Current.BoundingRectangle
    $closeBounds = $closeButton.Current.BoundingRectangle
    if ($closeBounds.Height -lt 20 -or $closeBounds.Top -lt $windowBounds.Top -or $closeBounds.Bottom -gt $windowBounds.Bottom) {
        throw "The completed Setup Close button is clipped. Window=$windowBounds Button=$closeBounds"
    }
    $closeButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if (-not $gui.WaitForExit(5000)) {
        throw 'The completed Setup Close button did not close the window.'
    }
}
finally {
    if (-not $gui.HasExited) {
        $gui.CloseMainWindow() | Out-Null
        if (-not $gui.WaitForExit(5000)) {
            $gui.Kill()
        }
    }
}

& (Join-Path $PSScriptRoot 'Test-Ui.ps1') -AppPath (Join-Path $work 'RightClip.exe')
if ($LASTEXITCODE -ne 0) {
    throw 'The installed app failed its UI smoke test.'
}
& (Join-Path $PSScriptRoot 'Test-Shell.ps1') -ShellPath (Join-Path $work 'RightClip.Shell.dll')
if ($LASTEXITCODE -ne 0) {
    throw 'The installed shell extension failed its smoke test.'
}
Write-Output "Setup portable install, upgrade, safety, icon, and payload checks passed: $($work)"
