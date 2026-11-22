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
    [string]$setupPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip-1.0.0-beta-win-x64-Setup.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $root 'TestResults\dotnet-bundle'
$env:RIGHTCLIP_SETUP_LOG_DIRECTORY = Join-Path $root 'TestResults\setup-logs'
New-Item -ItemType Directory -Force $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR, $env:RIGHTCLIP_SETUP_LOG_DIRECTORY | Out-Null
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

$setupLog = Get-ChildItem (Join-Path $env:RIGHTCLIP_SETUP_LOG_DIRECTORY 'setup-*.log') |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setupLog -or -not (Select-String -Path $setupLog.FullName -Pattern 'portable: True' -Quiet) -or
    -not (Select-String -Path $setupLog.FullName -Pattern 'Installation completed successfully' -Quiet)) {
    throw 'The installer did not write a complete setup log.'
}

$required = @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe', 'Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1',
    'RightClip.Identity.msix', 'LICENSE', 'NOTICE.md', 'README.md', 'SUPPORT.md', 'SECURITY.md', 'CONTRIBUTING.md', 'AGENTS.md',
    'docs\DEVELOPMENT.md', 'docs\RELEASING.md', 'docs\CODE_REVIEW.md', 'docs\images\trim-timeline.png',
    'ffmpeg-source.tar.gz', 'COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'COPYING.GPLv3',
    'zlib-1.4.tar.gz', 'openh264-2.7.0.tar.gz', 'kvazaar-2.3.2.tar.gz', 'libvpx-1.17.0.tar.gz', 'libaom-3.15.3.tar.gz',
    'licenses\dotnet-LICENSE.txt', 'licenses\dotnet-ThirdPartyNotices.txt',
    'licenses\zlib-LICENSE', 'licenses\openh264-LICENSE', 'licenses\kvazaar-LICENSE', 'licenses\libvpx-LICENSE', 'licenses\libvpx-PATENTS',
    'licenses\libaom-LICENSE', 'licenses\libaom-PATENTS', 'licenses\winpthreads-LICENSE',
    'ffmpeg-recipe\build.sh', 'ffmpeg-recipe\sources.json', 'ffmpeg-recipe\Dockerfile', 'ffmpeg-recipe\bootstrap-wsl.sh',
    'ffmpeg-recipe\licenses\winpthreads-COPYING')
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
$publishedInstaller = Get-Content -LiteralPath (Join-Path $work 'Install-RightClip.ps1') -Raw
if ($publishedInstaller -notmatch 'Get-AppxPackage -Name RightClip \| Remove-AppxPackage -ErrorAction Stop') {
    throw 'The installer does not remove existing RightClip packages before registration.'
}
if ($publishedInstaller -notmatch [regex]::Escape("ArgumentList @('/s', '/u'")) {
    throw 'The modern installer does not unregister legacy Explorer commands.'
}
if ($publishedInstaller -notmatch 'Restoring the previous RightClip menu failed\.') {
    throw 'The installer does not restore the previous menu when registration fails.'
}

$policyWork = Join-Path $root ('TestResults\uninstall-policy-' + [Guid]::NewGuid().ToString('N'))
try {
    $policyPayload = Join-Path $policyWork 'payload'
    New-Item -ItemType Directory -Path $policyPayload -Force | Out-Null
    foreach ($file in @('Install-RightClip.ps1', 'Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1')) {
        Copy-Item -LiteralPath (Join-Path $work $file) -Destination $policyPayload
        Set-Content -LiteralPath (Join-Path $policyPayload $file) -Stream Zone.Identifier -Value @('[ZoneTransfer]', 'ZoneId=3')
    }
    foreach ($file in @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe')) {
        Set-Content -LiteralPath (Join-Path $policyPayload $file) -Value 'uninstall policy fixture; never executed'
    }
    $policyProbe = Join-Path $policyWork 'Test-Policy.ps1'
    @'
<#
.SYNOPSIS
Stops a fixture installation before any real integration and checks its error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$installerPath,
    [Parameter(Mandatory = $true)][string]$target,
    [Parameter(Mandatory = $true)][string]$expectedError
)
$ErrorActionPreference = 'Stop'
function Start-Process {
    <#
    .SYNOPSIS
    Prevents the fixture from registering Explorer or making other changes.
    #>
    [CmdletBinding()]
    param([string]$filePath, [string[]]$argumentList, [switch]$wait, [switch]$passThru, [string]$windowStyle)
    throw 'IntegrationStoppedForTest'
}
function Remove-AppxPackage {
    <#
    .SYNOPSIS
    Prevents the fixture from removing an installed RightClip package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $inputObject
    )
    process { throw 'IntegrationStoppedForTest' }
}
function Add-AppxPackage {
    <#
    .SYNOPSIS
    Prevents the fixture from registering a RightClip package.
    #>
    [CmdletBinding()]
    param(
        [string]$path,
        [string]$externalLocation,
        [switch]$forceUpdateFromAnyVersion
    )
    throw 'IntegrationStoppedForTest'
}
try {
    & $installerPath -InstallDirectory $target
    throw 'The fixture unexpectedly completed installation.'
}
catch {
    if (-not $_.Exception.Message.Contains($expectedError)) { throw }
}
'@ | Set-Content -LiteralPath $policyProbe
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $policyTarget = Join-Path $policyWork 'installed'
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $policyProbe `
        -InstallerPath (Join-Path $policyPayload 'Install-RightClip.ps1') -Target $policyTarget -ExpectedError 'IntegrationStoppedForTest'
    if ($LASTEXITCODE -ne 0) { throw 'The marked payload did not pass uninstall script verification.' }
    foreach ($file in @('Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1')) {
        if (Get-Item -LiteralPath (Join-Path $policyTarget $file) -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
            throw "A verified uninstall script retained Mark of the Web: $($file)"
        }
    }
    $wrongTarget = Join-Path $policyWork 'wrong-target'
    New-Item -ItemType Directory -Path $wrongTarget | Out-Null
    $policyResult = & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
        -File (Join-Path $policyTarget 'Uninstall-RightClip.ps1') -InstallDirectory $wrongTarget 2>&1
    $policyExitCode = $LASTEXITCODE
    if ($policyExitCode -eq 0 -or ($policyResult -join ' ') -notmatch 'Run the uninstaller from the RightClip installation') {
        throw 'RemoteSigned did not execute both verified uninstall scripts up to their directory safety check.'
    }
    Add-Content -LiteralPath (Join-Path $policyPayload 'Assert-RightClipDirectory.ps1') -Value 'throw ''A modified helper must not execute.'''
    $tamperedTarget = Join-Path $policyWork 'tampered'
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $policyProbe `
        -InstallerPath (Join-Path $policyPayload 'Install-RightClip.ps1') -Target $tamperedTarget -ExpectedError 'Uninstall script integrity verification failed'
    if ($LASTEXITCODE -ne 0) { throw 'A modified uninstall helper was not rejected.' }
    if (Test-Path -LiteralPath $tamperedTarget) { throw 'An invalid payload changed the install directory.' }
    foreach ($file in @('Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1')) {
        if (-not (Get-Item -LiteralPath (Join-Path $policyPayload $file) -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
            throw 'The installer unblocked a payload before verifying both scripts.'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $policyWork) { Remove-Item -LiteralPath $policyWork -Recurse -Force }
}

$rollbackWork = Join-Path $root ('TestResults\menu-rollback-' + [Guid]::NewGuid().ToString('N'))
$packageBeforeRollback = @(Get-AppxPackage -Name RightClip | Select-Object -ExpandProperty PackageFullName)
$rollbackUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClip'
$rollbackShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\RightClip.lnk'
$rollbackUninstallBefore = if (Test-Path -LiteralPath $rollbackUninstallKey) { (Get-ItemProperty -LiteralPath $rollbackUninstallKey).DisplayVersion } else { '' }
$rollbackShortcutBefore = if (Test-Path -LiteralPath $rollbackShortcut) { (Get-Item -LiteralPath $rollbackShortcut).LastWriteTimeUtc.Ticks } else { 0 }
$legacyRollbackPaths = @(
    'HKCU:\Software\Classes\CLSID\{6B22FDB5-38A2-4EF0-9D8A-2C4D24E21001}'
    'HKCU:\Software\Classes\CLSID\{6B22FDB5-38A2-4EF0-9D8A-2C4D24E21002}'
    'HKCU:\Software\Classes\CLSID\{6B22FDB5-38A2-4EF0-9D8A-2C4D24E21003}'
    'HKCU:\Software\Classes\CLSID\{6B22FDB5-38A2-4EF0-9D8A-2C4D24E21005}'
)
foreach ($extension in @('.mp4', '.mov', '.mkv', '.webm')) {
    foreach ($handler in @('Trim', 'Tracks', 'Details', 'RemoveMetadata')) {
        $legacyRollbackPaths += "HKCU:\Software\Classes\SystemFileAssociations\$extension\shellex\ContextMenuHandlers\RightClip.$handler"
    }
}
$legacyBeforeRollback = @($legacyRollbackPaths | ForEach-Object { Test-Path -LiteralPath $_ })
try {
    $rollbackPayload = Join-Path $rollbackWork 'payload'
    $rollbackExternal = Join-Path $rollbackWork 'previous'
    New-Item -ItemType Directory -Path $rollbackPayload, $rollbackExternal -Force | Out-Null
    foreach ($file in @('Install-RightClip.ps1', 'Uninstall-RightClip.ps1', 'Assert-RightClipDirectory.ps1')) {
        Copy-Item -LiteralPath (Join-Path $work $file) -Destination $rollbackPayload
    }
    foreach ($file in @('RightClip.exe', 'RightClip.Shell.dll', 'ffmpeg.exe', 'ffprobe.exe')) {
        Set-Content -LiteralPath (Join-Path $rollbackPayload $file) -Value 'menu rollback fixture; never executed'
    }
    [IO.File]::WriteAllText((Join-Path $rollbackPayload 'RightClip.Identity.msix'), 'new-package')
    [IO.File]::WriteAllText((Join-Path $rollbackPayload 'RightClip.Identity.Production'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $rollbackExternal 'RightClip.Identity.msix'), 'previous-package')
    $rollbackProbe = Join-Path $rollbackWork 'Test-MenuRollback.ps1'
    @'
<#
.SYNOPSIS
Proves a failed ZIP registration restores the snapshotted package without calling the real Appx cmdlets.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$ExternalLocation,
    [Parameter(Mandatory = $true)][ValidateSet('legacy', 'modern')][string]$Mode
)
$ErrorActionPreference = 'Stop'
$log = Join-Path (Split-Path $InstallerPath -Parent) ("rollback-{0}.log" -f $Mode)
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
$env:RIGHTCLIP_FIXTURE_EXTERNAL = $ExternalLocation
$env:RIGHTCLIP_FIXTURE_TARGET = $Target
$env:RIGHTCLIP_FIXTURE_MODE = $Mode
$env:RIGHTCLIP_FIXTURE_LOG = $log
function Resolve-RightClipPackageExternalLocation {
    <#
    .SYNOPSIS
    Supplies the fixture package location to the installer.
    #>
    param([Parameter(Mandatory = $true)][string]$PackageFullName)
    if ($PackageFullName -ne 'RightClip_fixture_neutral__test') {
        throw "Unexpected package in the menu snapshot: $PackageFullName"
    }
    return $env:RIGHTCLIP_FIXTURE_EXTERNAL
}
function Get-AppxPackage {
    <#
    .SYNOPSIS
    Returns the fixture package instead of a package installed for the user.
    #>
    param([string]$Name)
    if ($Name -eq 'RightClip') {
        return [pscustomobject]@{ PackageFullName = 'RightClip_fixture_neutral__test' }
    }
}
function Remove-AppxPackage {
    <#
    .SYNOPSIS
    Records a removal without changing installed packages.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        Add-Content -LiteralPath $env:RIGHTCLIP_FIXTURE_LOG -Value 'REMOVE'
    }
}
function Add-AppxPackage {
    <#
    .SYNOPSIS
    Records a registration and fails only the package being installed.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$ExternalLocation, [switch]$ForceUpdateFromAnyVersion)
    Add-Content -LiteralPath $env:RIGHTCLIP_FIXTURE_LOG -Value ("ADD|{0}|{1}" -f $Path, $ExternalLocation)
    if ([IO.File]::ReadAllText($Path) -ne 'previous-package') {
        throw 'IntegrationStoppedForTest'
    }
}
function Start-Process {
    <#
    .SYNOPSIS
    Stops legacy registration and reports a successful unregistration for the modern path.
    #>
    [CmdletBinding()]
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$Wait, [switch]$PassThru, [string]$WindowStyle)
    Add-Content -LiteralPath $env:RIGHTCLIP_FIXTURE_LOG -Value ("START|{0}" -f ($ArgumentList -join '|'))
    if ($env:RIGHTCLIP_FIXTURE_MODE -eq 'modern') {
        return [pscustomobject]@{ ExitCode = 0 }
    }
    throw 'IntegrationStoppedForTest'
}
try {
    if ($Mode -eq 'modern') {
        & $InstallerPath -InstallDirectory $Target -ModernMenu
    }
    else {
        & $InstallerPath -InstallDirectory $Target
    }
    throw 'The fixture unexpectedly completed installation.'
}
catch {
    if (-not $_.Exception.Message.Contains('IntegrationStoppedForTest')) { throw }
}
$entries = @(Get-Content -LiteralPath $log)
$starts = @($entries | Where-Object { $_.StartsWith('START|') })
$restored = @($entries | Where-Object {
    $parts = $_.Split('|')
    $parts.Count -ge 3 -and $parts[0] -eq 'ADD' -and $parts[2] -eq $ExternalLocation
})
$unregistered = $false
if ($starts.Count -eq 1) {
    foreach ($part in $starts[0].Split('|')) {
        if ($part -eq '/u') { $unregistered = $true }
    }
}
if ($Mode -eq 'legacy') {
    if ($starts.Count -ne 1 -or $unregistered) {
        throw 'Legacy registration did not fail on the register command.'
    }
}
elseif ($starts.Count -ne 1 -or -not $unregistered) {
    throw 'Modern registration did not unregister legacy commands before restoring the menu.'
}
if ($restored.Count -ne 1) {
    throw 'Registration failure did not restore the previous RightClip package.'
}
'@ | Set-Content -LiteralPath $rollbackProbe -Encoding utf8
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($mode in @('legacy', 'modern')) {
        $rollbackTarget = Join-Path $rollbackWork $mode
        & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $rollbackProbe `
            -InstallerPath (Join-Path $rollbackPayload 'Install-RightClip.ps1') -Target $rollbackTarget `
            -ExternalLocation $rollbackExternal -Mode $mode
        if ($LASTEXITCODE -ne 0) { throw "The $mode installer did not restore the previous menu after registration failed." }
    }
    $packageAfterRollback = @(Get-AppxPackage -Name RightClip | Select-Object -ExpandProperty PackageFullName)
    if (($packageBeforeRollback -join '|') -ne ($packageAfterRollback -join '|')) {
        throw 'The menu rollback fixture changed an installed RightClip package.'
    }
    $legacyAfterRollback = @($legacyRollbackPaths | ForEach-Object { Test-Path -LiteralPath $_ })
    if (($legacyBeforeRollback -join '|') -ne ($legacyAfterRollback -join '|')) {
        throw 'The menu rollback fixture changed legacy Explorer registration.'
    }
    $rollbackUninstallAfter = if (Test-Path -LiteralPath $rollbackUninstallKey) { (Get-ItemProperty -LiteralPath $rollbackUninstallKey).DisplayVersion } else { '' }
    $rollbackShortcutAfter = if (Test-Path -LiteralPath $rollbackShortcut) { (Get-Item -LiteralPath $rollbackShortcut).LastWriteTimeUtc.Ticks } else { 0 }
    if ($rollbackUninstallBefore -ne $rollbackUninstallAfter -or $rollbackShortcutBefore -ne $rollbackShortcutAfter) {
        throw 'The menu rollback fixture changed the uninstall entry or Start Menu shortcut.'
    }
}
finally {
    if (Test-Path -LiteralPath $rollbackWork) { Remove-Item -LiteralPath $rollbackWork -Recurse -Force }
}

if (-not (Test-Path (Join-Path $work 'RightClip.Identity.Production'))) {
    $thumbprint = (Get-Content -LiteralPath (Join-Path $work 'RightClip.Identity.thumbprint') -Raw).Trim()
    $mismatchedThumbprint = $(if ($thumbprint[0] -eq '0') { '1' } else { '0' }) + $thumbprint.Substring(1)
    foreach ($helper in @('--trust-development-certificate', '--remove-development-certificate')) {
        $process = Start-Process -FilePath $setupPath -ArgumentList @($helper, $mismatchedThumbprint) -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 3) {
            throw "The packaged certificate helper did not reject mismatched trust safely (exit $($process.ExitCode))."
        }
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

$junctionRoot = Join-Path $root 'TestResults\installer-junction'
$junctionTarget = Join-Path $root 'TestResults\installer-junction-target'
foreach ($directory in @($junctionRoot, $junctionTarget)) {
    if (Test-Path $directory) {
        Remove-Item $directory -Recurse -Force
    }
    New-Item -ItemType Directory -Force $directory | Out-Null
}
$junction = Join-Path $junctionRoot 'linked'
New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
$linkedInstall = Join-Path $junction 'RightClip'
$process = Start-Process -FilePath $SetupPath -ArgumentList @('--silent', '--portable', '--install-dir', "`"$linkedInstall`"") -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -eq 0 -or (Test-Path (Join-Path $junctionTarget 'RightClip'))) {
    throw 'Setup installed through a junction or failed to reject it.'
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
    $trustCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'TrustDevelopmentCertificate')
    $trust = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $trustCondition)
    if (Test-Path (Join-Path $work 'RightClip.Identity.Production')) {
        if ($trust -and -not $trust.Current.IsOffscreen) {
            throw 'Production Setup displayed development certificate consent.'
        }
    }
    elseif (-not $trust -or
        $trust.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw 'Development Setup did not require explicit, unchecked certificate consent.'
    }
    $installCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Install'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
    $installButton = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $installCondition)
    if (-not $installButton -or -not $installButton.Current.IsEnabled) {
        throw 'The Setup Install button was not ready.'
    }
    $installButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    $successCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RightClip installation complete'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $gui.Id),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window))
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $successWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $successCondition)
        if ($successWindow) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $successWindow) {
        throw 'Setup did not show its installation-success modal.'
    }
    if (-not (Test-Path (Join-Path $guiWork 'RightClip.exe'))) {
        throw 'The Setup GUI did not honor portable installation mode.'
    }

    $successTitle = $successWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InstallSuccessTitle'))
    $exitButton = $successWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InstallSuccessExit'))
    $viewLogButton = $successWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'InstallSuccessViewLog'))
    if (-not $successTitle -or $successTitle.Current.Name -ne 'Install successful!' -or
        -not $exitButton -or -not $exitButton.Current.IsEnabled -or
        -not $viewLogButton -or -not $viewLogButton.Current.IsEnabled) {
        throw 'The installation-success modal did not expose its success title, View log, and Exit buttons.'
    }
    $successBounds = $successWindow.Current.BoundingRectangle
    foreach ($element in @($successTitle, $viewLogButton, $exitButton)) {
        $bounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $bounds.Height -lt 20 -or
            $bounds.Top -lt $successBounds.Top -or $bounds.Bottom -gt $successBounds.Bottom) {
            throw "The installation-success content is not visible without scrolling. Window=$successBounds Element=$bounds"
        }
    }
    $exitButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if (-not $gui.WaitForExit(5000)) {
        throw 'The installation-success Exit button did not close Setup.'
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
