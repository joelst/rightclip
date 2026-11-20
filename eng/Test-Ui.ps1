<#
.SYNOPSIS
Exercises timeline editing, denied-output recovery, and direct metadata removal.
.DESCRIPTION
Requires a published app with FFmpeg and an interactive Windows desktop.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$appPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip\RightClip.exe'),
    [string]$mediaPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Save-WindowScreenshot.ps1')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RightClipUiCapture
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr key, IntPtr data);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint key, uint mapType);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, System.UIntPtr extraInfo);

    private static uint ScaleToAbsolute(int pixel, int origin, int extent)
    {
        if (extent <= 1)
        {
            return 0;
        }

        var value = (pixel - origin) * 65535L / (extent - 1);
        if (value < 0)
        {
            return 0;
        }

        if (value > 65535)
        {
            return 65535;
        }

        return (uint)value;
    }

    private static void MouseAt(int x, int y, uint flags)
    {
        const uint absolute = 0x8000;
        const uint virtualDesktop = 0x4000;
        mouse_event(
            flags | absolute | virtualDesktop,
            ScaleToAbsolute(x, GetSystemMetrics(76), GetSystemMetrics(78)),
            ScaleToAbsolute(y, GetSystemMetrics(77), GetSystemMetrics(79)),
            0,
            System.UIntPtr.Zero);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScreenPoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out ScreenPoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(ScreenPoint point);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);

    public static string DescribePoint(int x, int y)
    {
        GetCursorPos(out var cursor);
        var under = WindowFromPoint(new ScreenPoint { X = x, Y = y });
        var title = new System.Text.StringBuilder(256);
        var className = new System.Text.StringBuilder(256);
        GetWindowText(under, title, title.Capacity);
        GetClassName(under, className, className.Capacity);
        var foregroundTitle = new System.Text.StringBuilder(256);
        GetWindowText(GetForegroundWindow(), foregroundTitle, foregroundTitle.Capacity);
        return $"cursor={cursor.X},{cursor.Y}; under={className}/{title}; foreground={foregroundTitle}; screen={GetSystemMetrics(78)}x{GetSystemMetrics(79)}";
    }

    public static void SendRightArrow(IntPtr window, bool down) => SendArrow(window, 0x27, down);

    public static void SendArrow(IntPtr window, ushort virtualKey, bool down)
    {
        var data = 1u | (MapVirtualKey(virtualKey, 0) << 16) | (1u << 24) | (down ? 0u : 0xc0000000u);
        SendMessage(window, down ? 0x100u : 0x101u, (IntPtr)virtualKey, (IntPtr)(long)data);
    }

    public static void DragVertical(int x, int y, int deltaY)
    {
        const uint move = 0x0001;
        const uint leftDown = 0x0002;
        const uint leftUp = 0x0004;
        SetCursorPos(x, y);
        MouseAt(x, y, move | leftDown);
        System.Threading.Thread.Sleep(40);
        for (var step = 1; step <= 6; step++)
        {
            var nextY = y + deltaY * step / 6;
            SetCursorPos(x, nextY);
            MouseAt(x, nextY, move);
            System.Threading.Thread.Sleep(30);
        }

        MouseAt(x, y + deltaY, move | leftUp);
    }

    public static void RightClick(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, System.UIntPtr.Zero);
        mouse_event(0x0010, 0, 0, 0, System.UIntPtr.Zero);
    }
}
'@
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root "TestResults\ui-smoke\$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$env:RIGHTCLIP_SETTINGS_PATH = Join-Path $work 'settings.json'
Set-Content -LiteralPath $env:RIGHTCLIP_SETTINGS_PATH -Value '{"SceneSensitivity":60,"SuppressCompletionNotification":true}' -Encoding utf8
$source = Join-Path $work 'source.mp4'
if ($MediaPath) {
    Copy-Item $MediaPath $source
}
else {
    $ffmpeg = Join-Path (Split-Path $AppPath -Parent) 'ffmpeg.exe'
    & $ffmpeg -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=3840x2160:rate=24:duration=60' `
        -f lavfi -i 'sine=frequency=440:duration=60' -c:v mpeg4 -g 24 -c:a aac $source
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate the UI smoke-test fixture.'
    }
}
$ffprobe = Join-Path (Split-Path $appPath -Parent) 'ffprobe.exe'
$sourceProbe = & $ffprobe -v error -select_streams v:0 -show_entries 'format=duration:stream=width,height:stream_side_data=rotation:stream_tags=rotate' -of json $source
if ($LASTEXITCODE -ne 0) {
    throw 'Could not probe the UI smoke-test fixture.'
}
$sourceDescription = $sourceProbe | ConvertFrom-Json
$sourceDuration = [double]::Parse($sourceDescription.format.duration, [Globalization.CultureInfo]::InvariantCulture)
$sourceVideo = $sourceDescription.streams[0]
if (-not $sourceVideo -or -not $sourceVideo.width -or -not $sourceVideo.height) {
    throw 'The UI smoke test could not determine the source video geometry.'
}
$rotation = 0
if ($sourceVideo.side_data_list -and $null -ne $sourceVideo.side_data_list[0].rotation) {
    $rotation = [int]$sourceVideo.side_data_list[0].rotation
}
elseif ($sourceVideo.tags.rotate) {
    $rotation = [int]$sourceVideo.tags.rotate
}
$expectedPreviewAspect = if ([Math]::Abs($rotation) % 180 -eq 90) {
    [double]$sourceVideo.height / $sourceVideo.width
}
else {
    [double]$sourceVideo.width / $sourceVideo.height
}
if ($sourceDuration -lt 0.1) {
    throw 'The UI smoke test needs a video at least 0.1 seconds long.'
}
$firstPosition = [Math]::Round($sourceDuration / 4, 3)
$middlePosition = [Math]::Round($sourceDuration / 2, 3)
$lastPosition = [Math]::Round($sourceDuration * 3 / 4, 3)
$movedPosition = [Math]::Round($sourceDuration * 5 / 8, 3)
$sourceHash = (Get-FileHash $source -Algorithm SHA256).Hash
$exportTimeoutSeconds = 45
$process = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"") -PassThru

function Wait-Window {
    <#
    .SYNOPSIS
    Waits for a window belonging to the test worker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$name,
        [ValidateRange(1, 300)][int]$timeoutSeconds = 30,
        $worker
    )

    if (-not $worker) {
        $worker = $process
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $worker.Id))
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($window) {
            return $window
        }
        $errorCondition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RightClip could not start'),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $worker.Id))
        $errorWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $errorCondition)
        if ($errorWindow) {
            $message = $errorWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text)) | ForEach-Object { $_.Current.Name }
            throw ($message -join ' | ')
        }
        if ($worker.HasExited) {
            throw "RightClip exited with code $($worker.ExitCode) before opening $Name."
        }
        Start-Sleep -Milliseconds 200
    }
    $processCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $worker.Id)
    $openWindows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $processCondition)
    $details = foreach ($openWindow in $openWindows) {
        $openWindow.Current.Name
        $openWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)) | ForEach-Object { $_.Current.Name }
    }
    throw "Timed out waiting for window '$Name'. Open UI: $($details -join ' | ')"
}

function Find-NamedElement {
    <#
    .SYNOPSIS
    Finds a UI Automation element by its accessible name and control type.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$parent, [Parameter(Mandatory = $true)][string]$name, [Parameter(Mandatory = $true)]$controlType)

    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ControlType))
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-AutomationElement {
    <#
    .SYNOPSIS
    Finds an element in the test window by its stable automation ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$parent,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$automationId
    )

    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
    return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-AutomationElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$parent,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$automationId,
        [ValidateRange(1, 30)][int]$timeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $element = Find-AutomationElement -Parent $Parent -AutomationId $AutomationId
        if ($element) {
            return $element
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for UI element '$AutomationId'."
}

function Start-LoadedEditor {
    <#
    .SYNOPSIS
    Starts one trim worker and waits until its video can be exported.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $started = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"") -PassThru
    $script:process = $started
    $editor = Wait-Window 'RightClip' -worker $started
    $ready = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $exportButton = Find-AutomationElement -Parent $editor -AutomationId 'ExportTimelineClips'
        if ($exportButton -and $exportButton.Current.IsEnabled) {
            return @{ Process = $started; Window = $editor; Export = $exportButton }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $ready)
    throw 'The editor did not finish loading the video.'
}

function Invoke-HideUntilExit {
    <#
    .SYNOPSIS
    Hides the writing windows and waits for the worker to exit after the operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$started,
        [Parameter(Mandatory = $true)]$editor,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$reason
    )

    $editorHandle = [IntPtr]$editor.Current.NativeWindowHandle
    $progressWindow = $null
    $hide = $null
    $hideBy = [DateTime]::UtcNow.AddSeconds(15)
    $windowCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $started.Id),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window))
    do {
        $ownedWindows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $windowCondition)
        $progressWindow = @($ownedWindows) | Where-Object { $_.Current.Name -eq 'RightClip working' } | Select-Object -First 1
        if ($progressWindow) {
            $hide = Find-AutomationElement -Parent $progressWindow -AutomationId 'HideOperationProgress'
            if ($hide) { break }
        }
        Start-Sleep -Milliseconds 40
    } while ([DateTime]::UtcNow -lt $hideBy -and -not $started.HasExited)
    if (-not $hide) {
        $visible = if ($progressWindow) {
            @($progressWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                ForEach-Object { "$($_.Current.AutomationId)=$($_.Current.Name)" }) -join ', '
        } else { 'no writing window' }
        throw "Hide was not available $reason. Open UI: $visible"
    }
    $progressHandle = [IntPtr]$progressWindow.Current.NativeWindowHandle
    $hide.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $hiddenWhileRunning = $false
    $hiddenBy = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $editorVisible = [RightClipUiCapture]::IsWindowVisible($editorHandle)
        $progressVisible = [RightClipUiCapture]::IsWindowVisible($progressHandle)
        if (-not $editorVisible -and -not $progressVisible -and -not $started.HasExited) {
            $hiddenWhileRunning = $true
            break
        }
        if ($started.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $hiddenBy)
    if (-not $hiddenWhileRunning) {
        throw "Hide did not conceal the editor and writing window while the worker was still running $reason."
    }
    if (-not $started.WaitForExit($exportTimeoutSeconds * 1000)) {
        throw "Hide did not exit after the operation finished $reason."
    }
    if ($started.ExitCode -ne 0) {
        throw "Hide did not exit cleanly after the operation finished $reason. Exit code: $($started.ExitCode)."
    }
}

$script:realFfmpegPath = $null
$script:parkedFfmpegPath = $null
$script:realFfmpegHash = $null

function Stop-AppDirectoryEncoder {
    <#
    .SYNOPSIS
    Stops RightClip and ffmpeg processes launched from the app directory so they release ffmpeg.exe.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AppDirectory)

    $root = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\')
    $targets = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('RightClip.exe', 'ffmpeg.exe') -and $_.ExecutablePath -and
            [string]::Equals([System.IO.Path]::GetDirectoryName($_.ExecutablePath), $root, [System.StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($target in $targets) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Restore-RightClipFfmpeg {
    <#
    .SYNOPSIS
    Copies the parked FFmpeg binary back over the stand-in and checks its hash.
    #>
    if (-not $script:realFfmpegPath -or -not $script:realFfmpegHash) {
        return
    }

    $appMatches = $false
    if (Test-Path -LiteralPath $script:realFfmpegPath) {
        try {
            $appMatches = (Get-FileHash -LiteralPath $script:realFfmpegPath -Algorithm SHA256 -ErrorAction Stop).Hash -eq $script:realFfmpegHash
        }
        catch {
            $appMatches = $false
        }
    }
    if (-not $script:parkedFfmpegPath -or -not (Test-Path -LiteralPath $script:parkedFfmpegPath)) {
        if ($appMatches) {
            $script:parkedFfmpegPath = $null
            return
        }

        throw "The parked FFmpeg binary is missing and the app copy does not match it. Parked: $($script:parkedFfmpegPath); app: $($script:realFfmpegPath)."
    }

    $appDirectory = Split-Path -Parent $script:realFfmpegPath
    $lastError = 'The restore did not run.'
    $restored = $false
    for ($attempt = 0; $attempt -lt 10 -and -not $restored; $attempt++) {
        try {
            Stop-AppDirectoryEncoder -AppDirectory $appDirectory
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 200
        try {
            Copy-Item -LiteralPath $script:parkedFfmpegPath -Destination $script:realFfmpegPath -Force -ErrorAction Stop
            $restored = (Get-FileHash -LiteralPath $script:realFfmpegPath -Algorithm SHA256 -ErrorAction Stop).Hash -eq $script:realFfmpegHash
            if (-not $restored) {
                $lastError = 'The copied file does not match the original FFmpeg hash.'
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $restored) {
        throw "Could not restore the original FFmpeg binary. The parked copy remains at $($script:parkedFfmpegPath). App copy: $($script:realFfmpegPath). $lastError"
    }

    Remove-Item -LiteralPath $script:parkedFfmpegPath -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $script:parkedFfmpegPath)) {
        $script:parkedFfmpegPath = $null
    }
}

$childProcesses = @()
try {
    $window = Wait-Window 'RightClip'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $export = Find-AutomationElement -Parent $window -AutomationId 'ExportTimelineClips'
        $position = Find-AutomationElement -Parent $window -AutomationId 'TimelinePosition'
        if ($export -and $export.Current.IsEnabled -and $position -and $position.Current.IsEnabled) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $export -or -not $export.Current.IsEnabled -or -not $position) {
        throw 'The selected video did not open directly in the timeline editor.'
    }

    $activeVideo = Find-AutomationElement -Parent $window -AutomationId 'ActiveVideoSelection'
    if (-not $activeVideo -or $activeVideo.Current.Name -ne 'source.mp4') {
        throw 'The Explorer-provided video did not open in the single-video editor.'
    }
    $range = $position.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    if ($range.Current.Minimum -ne 0 -or [Math]::Abs($range.Current.Maximum - $sourceDuration) -gt 0.05) {
        throw 'The timeline does not span the full video duration.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $timelineStatus = Find-NamedElement -Parent $window -Name 'Full video timeline' -ControlType ([System.Windows.Automation.ControlType]::Text)
        if ($timelineStatus) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $timelineStatus) {
        throw 'The full-length thumbnail timeline did not finish loading.'
    }
    $imageCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Image)
    if ($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $imageCondition).Count -lt 14) {
        throw 'The preview and full timeline thumbnails are missing.'
    }
    $initialClip = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1'
    if ($initialClip.FindAll([System.Windows.Automation.TreeScope]::Descendants, $imageCondition).Count -ne 1) {
        throw 'The initial clip did not receive its asynchronously loaded thumbnail.'
    }

    $openVideo = Find-NamedElement -Parent $window -Name 'Open video' -ControlType ([System.Windows.Automation.ControlType]::Button)
    if (-not $openVideo -or
        (Find-NamedElement -Parent $window -Name 'Add videos' -ControlType ([System.Windows.Automation.ControlType]::Button)) -or
        (Find-NamedElement -Parent $window -Name 'Remove' -ControlType ([System.Windows.Automation.ControlType]::Button))) {
        throw 'The editor still exposes multi-file controls instead of a single Open video action.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $inlinePreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
        $previewBounds = $inlinePreview.Current.BoundingRectangle
        if (-not $previewBounds.IsEmpty -and $previewBounds.Height -ge 100) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($previewBounds.Height -lt 100 -or [Math]::Abs($previewBounds.Width / $previewBounds.Height - $expectedPreviewAspect) -gt 0.02 -or
        $previewBounds.Width -gt $window.Current.BoundingRectangle.Width * 0.65) {
        throw "The inline preview did not retain the source aspect ratio $expectedPreviewAspect. Bounds: $previewBounds"
    }
    if ($previewBounds.Bottom -gt $position.Current.BoundingRectangle.Top) {
        throw 'The inline preview overlaps the timeline.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $loading = Find-AutomationElement -Parent $window -AutomationId 'LoadingIndicator'
        if (-not $loading -or $loading.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $window.SetFocus()
    $initialEditorBounds = $window.Current.BoundingRectangle
    $initialEditorScale = $initialEditorBounds.Width / 1080
    $editorTransform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $editorTransform.Resize($initialEditorBounds.Width, $initialEditorBounds.Height + 200 * $initialEditorScale)
    Start-Sleep -Milliseconds 250
    $previewBounds = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle
    $resizePreview = Find-AutomationElement -Parent $window -AutomationId 'ResizePreview'
    $resizeBounds = $resizePreview.Current.BoundingRectangle
    $resizeX = [int]($resizeBounds.Left + $resizeBounds.Width / 2)
    $resizeY = [int]($resizeBounds.Top + $resizeBounds.Height / 2)
    [RightClipUiCapture]::DragVertical($resizeX, $resizeY, 50)
    Start-Sleep -Milliseconds 250
    $resizedPreviewBounds = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle
    if ($resizedPreviewBounds.Height -lt $previewBounds.Height + 40 -or
        [Math]::Abs($resizedPreviewBounds.Width / $resizedPreviewBounds.Height - $expectedPreviewAspect) -gt 0.02) {
        $point = [RightClipUiCapture]::DescribePoint($resizeX, $resizeY)
        throw "The inline preview did not resize with its aspect ratio intact: before=$previewBounds; grip=$resizeBounds; after=$resizedPreviewBounds; gripOffscreen=$($resizePreview.Current.IsOffscreen); window=$($window.Current.BoundingRectangle); initial=$initialEditorBounds; $point"
    }
    $resizePreview = Find-AutomationElement -Parent $window -AutomationId 'ResizePreview'
    if (-not $resizePreview.Current.IsKeyboardFocusable) {
        throw 'The preview resize grip is not keyboard focusable.'
    }
    $resizePreview.SetFocus()
    Start-Sleep -Milliseconds 150
    $keyboardBefore = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    $editorHandle = [IntPtr]$window.Current.NativeWindowHandle
    [RightClipUiCapture]::SendArrow($editorHandle, 0x28, $true)
    [RightClipUiCapture]::SendArrow($editorHandle, 0x28, $false)
    Start-Sleep -Milliseconds 200
    $keyboardAfter = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    if ($keyboardAfter -lt $keyboardBefore + 4) {
        throw "The preview resize grip did not grow the preview from the Down arrow: before=$keyboardBefore; after=$keyboardAfter"
    }
    [RightClipUiCapture]::SendArrow($editorHandle, 0x26, $true)
    [RightClipUiCapture]::SendArrow($editorHandle, 0x26, $false)
    Start-Sleep -Milliseconds 200
    $keyboardRestored = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    if ([Math]::Abs($keyboardRestored - $keyboardBefore) -gt 4) {
        throw "The preview resize grip did not restore the preview from the Up arrow: before=$keyboardBefore; after=$keyboardRestored"
    }
    $resizeBounds = (Find-AutomationElement -Parent $window -AutomationId 'ResizePreview').Current.BoundingRectangle
    [RightClipUiCapture]::DragVertical(
        [int]($resizeBounds.Left + $resizeBounds.Width / 2),
        [int]($resizeBounds.Top + $resizeBounds.Height / 2), -50)
    Start-Sleep -Milliseconds 250
    $editorTransform.Resize($initialEditorBounds.Width, $initialEditorBounds.Height)
    Start-Sleep -Milliseconds 250
    $mainBounds = $window.Current.BoundingRectangle
    $popOut = Find-AutomationElement -Parent $window -AutomationId 'PopOutPreview'
    $popOut.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $detachedWindow = Wait-Window 'RightClip preview'
    if (-not $inlinePreview.Current.IsOffscreen) {
        throw 'The inline preview still occupied the editor after being popped out.'
    }
    $detachedWindow.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Resize(700, 500)
    Start-Sleep -Milliseconds 250
    $detachedBounds = $detachedWindow.Current.BoundingRectangle
    $resizedMainBounds = $window.Current.BoundingRectangle
    if ([Math]::Abs($detachedBounds.Width - 700) -gt 2 -or [Math]::Abs($detachedBounds.Height - 500) -gt 2 -or
        [Math]::Abs($resizedMainBounds.Width - $mainBounds.Width) -gt 1 -or
        [Math]::Abs($resizedMainBounds.Height - $mainBounds.Height) -gt 1) {
        throw 'Resizing the detached preview changed its requested size or resized the main editor.'
    }
    $detachedWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $inlinePreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
        if ($inlinePreview -and -not $inlinePreview.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $inlinePreview -or $inlinePreview.Current.IsOffscreen) {
        throw 'Closing the detached preview did not restore the inline frame.'
    }
    $window.SetFocus()

    $add = Find-AutomationElement -Parent $window -AutomationId 'AddTimelineCut'
    $reset = Find-AutomationElement -Parent $window -AutomationId 'ResetTimelineCuts'
    $range.SetValue($firstPosition)
    $timelineMenu = Find-AutomationElement -Parent $window -AutomationId 'TimelineContextMenu'
    $timelineMenu.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $contextCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'AddTimelineContextCut'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $contextCut = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $contextCondition)
        if ($contextCut) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $contextCut -or -not $contextCut.Current.IsEnabled) {
        throw 'The accessible timeline context menu did not offer Add cut here.'
    }
    $contextCut.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $firstCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
        if ($firstCut) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $actualCutPosition = if ($firstCut) { $firstCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value } else { -1 }
    if (-not $firstCut -or [Math]::Abs($actualCutPosition - $firstPosition) -gt 0.05) {
        throw "The context menu did not add its cut at the selected timeline position. Actual=$actualCutPosition; Expected=$firstPosition; Playhead=$($range.Current.Value)"
    }
    $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ((Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1') -or
        (Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2')) {
        throw 'Reset cuts did not restore a single full-length piece.'
    }

    $range.SetValue($firstPosition)
    $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $startPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1'
    $startPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $startPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1'
    $endPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    if ($startPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::Off -or
        $endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On -or $export.Current.Name -ne 'Export clip') {
        throw 'A single cut did not allow excluding the start and including only the end.'
    }
    $startPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $endPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    $endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $startPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1'
    $endPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    if ($startPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On -or
        $endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::Off -or $export.Current.Name -ne 'Export clip') {
        throw 'A single cut did not allow including only the start and excluding the end.'
    }
    $endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    $range.SetValue($sourceDuration - 1 / 24)
    $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $endPiece = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    if ($endPiece.Current.BoundingRectangle.Width -gt 12) {
        throw 'The end-piece regression did not create a narrow final frame.'
    }
    $endCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $cutBounds = $endCut.Current.BoundingRectangle
    [RightClipUiCapture]::RightClick([int]($cutBounds.Left + $cutBounds.Width / 2),
        [int]($cutBounds.Top + 12))
    $toggleCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ToggleClipAfterCut1'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $toggleAfter = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $toggleCondition)
        if ($toggleAfter) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $toggleAfter -or $toggleAfter.Current.Name -ne 'Exclude clip after cut') {
        throw 'The narrow final frame did not offer an Exclude action on its cut marker.'
    }
    $toggleAfter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $endPiece = Wait-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    $startPiece = Wait-AutomationElement -Parent $window -AutomationId 'TimelineClip1'
    if ($endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::Off -or
        $startPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On -or $export.Current.Name -ne 'Export clip') {
        throw 'The cut-marker action did not exclude only the narrow final frame.'
    }

    $endCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $cutBounds = $endCut.Current.BoundingRectangle
    [RightClipUiCapture]::RightClick([int]($cutBounds.Left + $cutBounds.Width / 2),
        [int]($cutBounds.Top + 12))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $toggleAfter = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $toggleCondition)
        if ($toggleAfter) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $toggleAfter -or $toggleAfter.Current.Name -ne 'Include clip after cut') {
        throw 'The excluded final frame did not offer an Include action on its cut marker.'
    }
    $toggleAfter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $endPiece = Wait-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    if ($endPiece.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
        [System.Windows.Automation.ToggleState]::On) {
        throw 'The cut-marker action did not include the narrow final frame again.'
    }
    $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $precisionPosition = [Math]::Round($sourceDuration / 7, 7)
    $range.SetValue($precisionPosition)
    $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $precisionCut = Wait-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $precisionCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue($precisionPosition + 0.01)
    $precisionCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $precisionCut.SetFocus()
    $removePrecision = Find-AutomationElement -Parent $window -AutomationId 'RemoveTimelineCut'
    $removePrecision.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if (Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1') {
        throw 'A fractional-timestamp cut could not be selected and removed exactly.'
    }
    foreach ($timestamp in @($firstPosition, $middlePosition, $lastPosition)) {
        $range.SetValue($timestamp)
        $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    $clipBounds = @(1..4 | ForEach-Object {
        (Wait-AutomationElement -Parent $window -AutomationId "TimelineClip$_").Current.BoundingRectangle
    })
    for ($index = 1; $index -lt $clipBounds.Count; $index++) {
        if ($clipBounds[$index].Width -lt 1 -or $clipBounds[$index - 1].Right -gt $clipBounds[$index].Left + 1) {
            throw "Clips overlap or are hidden: $($clipBounds -join ' | ')"
        }
    }
    $zoomIn = Find-AutomationElement -Parent $window -AutomationId 'TimelineZoomIn'
    $fit = Find-AutomationElement -Parent $window -AutomationId 'TimelineFit'
    $zoomIn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $zoomedBounds = (Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1').Current.BoundingRectangle
    if ($zoomedBounds.Width -le $clipBounds[0].Width + 1) {
        throw "Zoom did not enlarge the timeline clips: $($clipBounds[0].Width) to $($zoomedBounds.Width)."
    }
    $fit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $fitBounds = (Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1').Current.BoundingRectangle
    if ([Math]::Abs($fitBounds.Width - $clipBounds[0].Width) -gt 1) {
        throw 'Fit did not restore the full-video timeline.'
    }
    $secondCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut2'
    $secondCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue($movedPosition)
    $secondCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut2'
    if ($secondCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value -ne $movedPosition) {
        throw 'Moving a cut did not update its timeline position.'
    }
    $secondCut.SetFocus()
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedId = if ($focusedElement) { $focusedElement.Current.AutomationId } else { '' }
        if ($focusedId -eq 'TimelineCut2') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)
    if ($focusedId -ne 'TimelineCut2') {
        throw "Could not focus the cut before keyboard movement; focused element was '$focusedId'."
    }
    $mainHandle = [IntPtr]$window.Current.NativeWindowHandle
    [RightClipUiCapture]::SendRightArrow($mainHandle, $true)
    try {
        $heldCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut2'
        $heldPosition = $heldCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value
        if ([Math]::Abs($heldPosition - ($movedPosition + 0.04)) -gt 0.001) {
            throw 'An arrow key-down moved only the visual thumb instead of committing the timeline boundary.'
        }
    }
    finally { [RightClipUiCapture]::SendRightArrow($mainHandle, $false) }
    [RightClipUiCapture]::SendRightArrow($mainHandle, $true)
    try { Start-Sleep -Milliseconds 250 }
    finally { [RightClipUiCapture]::SendRightArrow($mainHandle, $false) }
    $window.SetFocus()
    $secondCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut2'
    $expectedKeyboardPosition = $movedPosition + 0.08
    $keyboardPosition = $secondCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value
    if ([Math]::Abs($keyboardPosition - $expectedKeyboardPosition) -gt 0.011) {
        throw "Repeated arrow keys did not move the cut by 0.08 seconds; expected $expectedKeyboardPosition but got $keyboardPosition."
    }
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedId = if ($focusedElement) { $focusedElement.Current.AutomationId } else { '' }
        if ($focusedId -eq 'TimelineCut2') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)
    if ($focusedId -ne 'TimelineCut2') {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedDetails = if ($focused) { "name='$($focused.Current.Name)', type=$($focused.Current.ControlType.ProgrammaticName), process=$($focused.Current.ProcessId), id='$($focused.Current.AutomationId)'" } else { '<null>' }
        $foreground = [RightClipUiCapture]::GetForegroundWindow()
        $mainState = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
        throw "Keyboard focus was not restored. Focus: $focusedDetails; foreground=$foreground; main=$($window.Current.NativeWindowHandle), state=$mainState, offscreen=$($window.Current.IsOffscreen); cut offscreen=$($secondCut.Current.IsOffscreen), focusable=$($secondCut.Current.IsKeyboardFocusable)."
    }
    [System.Windows.Forms.SendKeys]::SendWait('{LEFT}')
    Start-Sleep -Milliseconds 600
    $window.SetFocus()
    $secondCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut2'
    $expectedKeyboardPosition = $movedPosition + 0.04
    $keyboardPosition = $secondCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value
    if ([Math]::Abs($keyboardPosition - $expectedKeyboardPosition) -gt 0.011) {
        throw "A later keyboard edit failed; expected $expectedKeyboardPosition but got $keyboardPosition."
    }
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedId = if ($focusedElement) { $focusedElement.Current.AutomationId } else { '' }
        if ($focusedId -eq 'TimelineCut2') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)
    if ($focusedId -ne 'TimelineCut2') {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedDetails = if ($focused) { "name='$($focused.Current.Name)', type=$($focused.Current.ControlType.ProgrammaticName), process=$($focused.Current.ProcessId), id='$($focused.Current.AutomationId)'" } else { '<null>' }
        $foreground = [RightClipUiCapture]::GetForegroundWindow()
        $mainState = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
        throw "Later keyboard focus was not restored. Focus: $focusedDetails; foreground=$foreground; main=$($window.Current.NativeWindowHandle), state=$mainState, offscreen=$($window.Current.IsOffscreen); cut offscreen=$($secondCut.Current.IsOffscreen), focusable=$($secondCut.Current.IsKeyboardFocusable)."
    }
    $thirdCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut3'
    $thirdCut.SetFocus()
    $remove = Find-AutomationElement -Parent $window -AutomationId 'RemoveTimelineCut'
    $remove.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if (Find-AutomationElement -Parent $window -AutomationId 'TimelineCut3') {
        throw 'Removing a cut did not merge the neighboring pieces.'
    }
    $middle = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
    $middle.SetFocus()
    $middle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $middle = Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2'
        if ($middle -and $middle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [System.Windows.Automation.ToggleState]::Off) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $middle -or $middle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw 'The excluded clip remained selected.'
    }
    $window.SetFocus()
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedId = if ($focusedElement) { $focusedElement.Current.AutomationId } else { '' }
        if ($focusedId -eq 'TimelineClip2') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)
    if ($focusedId -ne 'TimelineClip2') {
        throw "Toggling a clip did not restore its keyboard focus; focused element was '$focusedId'."
    }
    $range.SetValue($firstPosition)
    $previewTime = [TimeSpan]::FromSeconds($firstPosition).ToString('hh\:mm\:ss\.fff', [Globalization.CultureInfo]::InvariantCulture)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $previewTimeElement = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewTime'
        $previewFrame = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
        $frameReady = Find-NamedElement -Parent $window -Name 'Frame preview' -ControlType ([System.Windows.Automation.ControlType]::Text)
        if ($previewTimeElement.Current.Name -eq $previewTime -and $frameReady) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $frameReady -or $previewTimeElement.Current.Name -ne $previewTime) {
        throw 'The timeline did not render the expected video frame and external time readout.'
    }
    $previewBounds = $previewFrame.Current.BoundingRectangle
    if ($previewTimeElement.Current.BoundingRectangle.Bottom -gt $previewBounds.Top) {
        throw 'The playhead time is not outside the preview image.'
    }
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    foreach ($overlayText in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition)) {
        $textBounds = $overlayText.Current.BoundingRectangle
        $overlapsPreview = $textBounds.Left -lt $previewBounds.Right -and $textBounds.Right -gt $previewBounds.Left -and
            $textBounds.Top -lt $previewBounds.Bottom -and $textBounds.Bottom -gt $previewBounds.Top
        if ($overlapsPreview -and
            ($overlayText.Current.Name.Contains('source.mp4') -or $overlayText.Current.Name.Contains($previewTime))) {
            throw "The preview still contains a filename or time overlay: $($overlayText.Current.Name)"
        }
    }

    $assertTrimContentVisible = {
        $tabs = Find-AutomationElement -Parent $window -AutomationId 'TrimTabs'
        $trimAdvanced = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
        $advancedHeader = $trimAdvanced.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text))
        if (-not $advancedHeader) {
            throw 'The Advanced expander did not expose its header text to UI automation.'
        }
        foreach ($element in @($add, $position, $trimAdvanced, $advancedHeader)) {
            if (-not $element -or $element.Current.IsOffscreen -or
                $element.Current.BoundingRectangle.Bottom -gt $tabs.Current.BoundingRectangle.Bottom) {
                throw "A Trim control is clipped by the tab boundary. Id=$($element.Current.AutomationId); Name=$($element.Current.Name); Bounds=$($element.Current.BoundingRectangle); Tabs=$($tabs.Current.BoundingRectangle)"
            }
        }
    }
    $bounds = $window.Current.BoundingRectangle
    $assertAdvancedContentVisible = {
        $advancedOptions = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
        $expansion = $advancedOptions.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expansion.Expand()
        Start-Sleep -Milliseconds 250
        $trimReview = Find-NamedElement -Parent $window -Name 'Review trim / scene operation' -ControlType ([System.Windows.Automation.ControlType]::Button)
        $scrollItem = $null
        if ($trimReview.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
            $scrollItem.ScrollIntoView()
        }
        else {
            $scrollCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty, $true)
            $scrollViewer = $advancedOptions.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $scrollCondition)
            if ($scrollViewer) {
                $scrollViewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 100)
            }
        }
        Start-Sleep -Milliseconds 150
        $tabs = Find-AutomationElement -Parent $window -AutomationId 'TrimTabs'
        if ($trimReview.Current.IsOffscreen -or $trimReview.Current.BoundingRectangle.Height -lt 10 -or
            $trimReview.Current.BoundingRectangle.Bottom -gt $tabs.Current.BoundingRectangle.Bottom) {
            throw 'Expanded Advanced controls cannot scroll the trim-review button into the tab.'
        }
        $expansion.Collapse()
    }
    foreach ($element in @($add, $position, $export)) {
        $elementBounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $elementBounds.Height -lt 10 -or $elementBounds.Bottom -gt $bounds.Bottom) {
            throw 'A primary timeline control is clipped or requires scrolling.'
        }
    }
    $advancedOptions = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
    $expansion = $advancedOptions.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expansion.Expand()
    $startInput = Find-AutomationElement -Parent $window -AutomationId 'TrimStartInput'
    $startInput.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('3')
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $fieldPreviewTime = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewTime'
        $fieldPreviewReady = Find-NamedElement -Parent $window -Name 'Frame preview' -ControlType ([System.Windows.Automation.ControlType]::Text)
        if ($fieldPreviewTime.Current.Name -eq '00:00:03.000' -and $fieldPreviewReady) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $fieldPreviewReady -or $fieldPreviewTime.Current.Name -ne '00:00:03.000') {
        throw 'An Advanced time field showed a frame without synchronizing the external preview timestamp.'
    }
    $expansion.Collapse()
    Start-Sleep -Milliseconds 250
    & $assertTrimContentVisible
    & $assertAdvancedContentVisible
    $transform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $scale = $bounds.Width / 1080
    $customPreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
    $customPreviewHeight = $customPreview.Current.BoundingRectangle.Height
    $resizePreview = Find-AutomationElement -Parent $window -AutomationId 'ResizePreview'
    $resizeBounds = $resizePreview.Current.BoundingRectangle
    [RightClipUiCapture]::DragVertical(
        [int]($resizeBounds.Left + $resizeBounds.Width / 2),
        [int]($resizeBounds.Top + $resizeBounds.Height / 2), 180)
    Start-Sleep -Milliseconds 250
    $enlargedPreviewHeight = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    $advancedExpansion = (Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions').
        GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $advancedExpansion.Expand()
    Start-Sleep -Milliseconds 300
    $advancedPreviewHeight = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    if ($advancedPreviewHeight -gt $enlargedPreviewHeight - 40) {
        throw "Expanding Advanced left the enlarged preview covering its controls: before=$enlargedPreviewHeight; after=$advancedPreviewHeight"
    }
    $trimReview = Find-NamedElement -Parent $window -Name 'Review trim / scene operation' -ControlType ([System.Windows.Automation.ControlType]::Button)
    $scrollItem = $null
    if ($trimReview.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
        $scrollItem.ScrollIntoView()
    }
    $advancedTabs = Find-AutomationElement -Parent $window -AutomationId 'TrimTabs'
    if ($trimReview.Current.IsOffscreen -or $trimReview.Current.BoundingRectangle.Height -lt 10 -or
        $trimReview.Current.BoundingRectangle.Bottom -gt $advancedTabs.Current.BoundingRectangle.Bottom) {
        throw 'Expanding Advanced did not keep the trim-review button inside the tab.'
    }
    $advancedExpansion.Collapse()
    Start-Sleep -Milliseconds 300
    $collapsedPreviewHeight = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    if ([Math]::Abs($collapsedPreviewHeight - $enlargedPreviewHeight) -gt 12) {
        throw "Collapsing Advanced did not restore the enlarged preview: before=$enlargedPreviewHeight; after=$collapsedPreviewHeight"
    }
    $transform.Resize(850 * $scale, 750 * $scale)
    Start-Sleep -Milliseconds 250
    & $assertTrimContentVisible
    $customPreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
    if ($customPreview.Current.BoundingRectangle.Bottom -gt $position.Current.BoundingRectangle.Top) {
        throw 'A custom preview height clipped or overlapped Trim controls after a compact window resize.'
    }
    $transform.Resize($bounds.Width, $bounds.Height)
    Start-Sleep -Milliseconds 250
    $resizePreview = Find-AutomationElement -Parent $window -AutomationId 'ResizePreview'
    $resizeBounds = $resizePreview.Current.BoundingRectangle
    $grownPreviewHeight = (Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage').Current.BoundingRectangle.Height
    $restoreDelta = [int]($customPreviewHeight - $grownPreviewHeight)
    if ($restoreDelta -ne 0) {
        [RightClipUiCapture]::DragVertical(
            [int]($resizeBounds.Left + $resizeBounds.Width / 2),
            [int]($resizeBounds.Top + $resizeBounds.Height / 2), $restoreDelta)
        Start-Sleep -Milliseconds 250
    }
    $transform.Resize(850 * $scale, 700 * $scale)
    Start-Sleep -Milliseconds 250
    $minimumBounds = $window.Current.BoundingRectangle
    $advanced = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
    foreach ($element in @($add, $position, $export, $advanced, $popOut)) {
        $elementBounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $elementBounds.Height -lt 10 -or $elementBounds.Bottom -gt $minimumBounds.Bottom) {
            throw 'A primary timeline control is clipped at the minimum window size.'
        }
    }
    $compactPreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
    if ($compactPreview.Current.BoundingRectangle.Height -gt 1) {
        throw 'The inline preview still crowded the compact layout instead of collapsing.'
    }
    if ($advanced.Current.BoundingRectangle.Bottom -ge $export.Current.BoundingRectangle.Top) {
        throw 'The minimum window size overlaps the timeline editor and export controls.'
    }
    & $assertAdvancedContentVisible
    $transform.Resize($bounds.Width, $bounds.Height)
    Start-Sleep -Milliseconds 250
    & $assertTrimContentVisible
    Save-WindowScreenshot -WindowHandle ([IntPtr]$window.Current.NativeWindowHandle) `
        -Path (Join-Path $root 'TestResults\trim-timeline.png') | Out-Null

    $outputs = @((Join-Path $work 'source.clip01.mp4'), (Join-Path $work 'source.clip02.mp4'))
    $originalAcl = Get-Acl -LiteralPath $work
    $deniedAcl = Get-Acl -LiteralPath $work
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User, [Security.AccessControl.FileSystemRights]::CreateFiles,
            [Security.AccessControl.InheritanceFlags]::None, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Deny))
        Set-Acl -LiteralPath $work -AclObject $deniedAcl
        Set-Content -LiteralPath $env:RIGHTCLIP_SETTINGS_PATH -Value '{"SceneSensitivity":60,"SuppressCompletionNotification":false}' -Encoding utf8
        $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $errorWindow = Wait-Window 'RightClip working' -timeoutSeconds 10
        $settingsDuringOpen = Get-Content -LiteralPath $env:RIGHTCLIP_SETTINGS_PATH -Raw | ConvertFrom-Json
        if ($settingsDuringOpen.SuppressCompletionNotification) {
            throw 'Opening the writing window saved the skip-notification preference without a user change.'
        }
        $failureSkip = Find-AutomationElement -Parent $errorWindow -AutomationId 'SkipCompletionNotification'
        if ($failureSkip -and
            $failureSkip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On) {
            throw 'The blocked-export regression scenario did not load its saved skip-notification preference.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $ok = Find-AutomationElement -Parent $errorWindow -AutomationId 'OperationResultReturn'
            if ($ok -and -not $ok.Current.IsOffscreen) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $ok -or $ok.Current.IsOffscreen -or $process.HasExited) {
            throw 'A blocked output did not remain visible for retry when skip notification was enabled.'
        }
        $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $summary = Find-AutomationElement -Parent $window -AutomationId 'OperationSummary'
            if ($summary -and $summary.Current.Name.Contains('Controlled folder access') -and $export.Current.IsEnabled) {
                break
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $summary -or -not $summary.Current.Name.Contains('Controlled folder access') -or -not $export.Current.IsEnabled) {
            throw 'A blocked output did not show actionable folder-access guidance and re-enable export.'
        }
        if (Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4') {
            throw 'The blocked export left a completed clip behind.'
        }
    }
    finally {
        Set-Acl -LiteralPath $work -AclObject $originalAcl
        $identity.Dispose()
    }
    if ((Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2').
        GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw 'The failed export changed the selected pieces.'
    }
    $popOut = Find-AutomationElement -Parent $window -AutomationId 'PopOutPreview'
    $popOut.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Window 'RightClip preview' | Out-Null
    $firstCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $firstCut.SetFocus()
    $firstPosition += 0.32
    $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState(
        [System.Windows.Automation.WindowVisualState]::Maximized)
    Start-Sleep -Milliseconds 200
    try {
        for ($repeat = 0; $repeat -lt 8; $repeat++) { [RightClipUiCapture]::SendRightArrow($mainHandle, $true) }
        $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    finally { [RightClipUiCapture]::SendRightArrow($mainHandle, $false) }
    $resultWindow = Wait-Window 'RightClip working' -timeoutSeconds 10
    $skipAfterFailure = Wait-AutomationElement -Parent $resultWindow -AutomationId 'SkipCompletionNotification'
    $skipAfterFailurePattern = $skipAfterFailure.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($skipAfterFailurePattern.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {
        $skipAfterFailurePattern.Toggle()
    }
    $detachedCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RightClip preview'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remainingPreview = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $detachedCondition)
        if (-not $remainingPreview) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remainingPreview) {
        throw 'Starting a write left the detached preview visible after hiding its owner.'
    }
    $resultWindow.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Resize(560, 220)
    $resultState = $resultWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if ($resultWindow.Current.IsOffscreen -or $resultState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'The writing window was not visibly normal during export.'
    }
    if ([RightClipUiCapture]::IsWindowVisible($mainHandle)) {
        throw 'The editor remained visible and usable during writing.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($exportTimeoutSeconds)
    do {
        $returnToApp = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationResultReturn'
        if ($returnToApp -and -not $returnToApp.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $resultTitle = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationProgressTitle'
    $resultSummary = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationResultSummary'
    $closeApp = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationResultCloseApp'
    if (-not $returnToApp -or $returnToApp.Current.IsOffscreen -or -not $closeApp -or
        $resultTitle.Current.Name -ne 'Writing completed' -or -not $resultSummary.Current.Name.Contains('2 new outputs')) {
        throw "The writing window did not show its completion summary and both exit choices: $($resultSummary.Current.Name)"
    }
    $resultBounds = $resultWindow.Current.BoundingRectangle
    foreach ($element in @($returnToApp, $closeApp)) {
        $elementBounds = $element.Current.BoundingRectangle
        if ($elementBounds.Bottom -gt $resultBounds.Bottom -or $elementBounds.Top -lt $resultBounds.Top) {
            throw 'Completion actions were clipped after manually resizing the writing window.'
        }
    }
    $resultWindow.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Resize(560, 240)
    Start-Sleep -Milliseconds 250
    $shrunkResultBounds = $resultWindow.Current.BoundingRectangle
    $openOutput = Find-NamedElement -Parent $resultWindow -Name 'Open output folder' -ControlType ([System.Windows.Automation.ControlType]::Button)
    foreach ($element in @($returnToApp, $closeApp, $openOutput)) {
        $elementBounds = $element.Current.BoundingRectangle
        if (-not $element -or $element.Current.IsOffscreen -or $elementBounds.Height -lt 10 -or
            $elementBounds.Top -lt $shrunkResultBounds.Top -or $elementBounds.Bottom -gt $shrunkResultBounds.Bottom -or
            $elementBounds.Left -lt $shrunkResultBounds.Left -or $elementBounds.Right -gt $shrunkResultBounds.Right) {
            throw "A completion action was clipped after shrinking the writing window: $($element.Current.Name); button=$elementBounds; window=$shrunkResultBounds"
        }
    }
    if ([RightClipUiCapture]::IsWindowVisible($mainHandle)) {
        throw 'The editor became visible while the completion summary was shown.'
    }
    $returnToApp.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
    $baseWindowState = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if (-not [RightClipUiCapture]::IsWindowVisible($mainHandle) -or
        $window.Current.IsOffscreen -or $baseWindowState -ne [System.Windows.Automation.WindowVisualState]::Maximized) {
        throw 'Return to app did not restore the maximized editor.'
    }
    $inlinePreview = Find-AutomationElement -Parent $window -AutomationId 'InlinePreviewImage'
    if (-not $inlinePreview -or $inlinePreview.Current.IsOffscreen) {
        throw 'Closing the detached preview for writing did not restore the inline preview on Return to app.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $outputs[1]) -and $export.Current.IsEnabled) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    for ($index = 0; $index -lt $outputs.Count; $index++) {
        $probeOutput = & $ffprobe -v error -show_entries format=duration -of json $outputs[$index]
        if ($LASTEXITCODE -ne 0) {
            throw 'The selected clip export did not finish a readable output.'
        }
        $duration = [double]::Parse(($probeOutput | ConvertFrom-Json).format.duration, [Globalization.CultureInfo]::InvariantCulture)
        $expected = if ($index -eq 0) { $firstPosition } else { $sourceDuration - $movedPosition }
        if ([Math]::Abs($duration - $expected) -gt 0.2) {
            throw "Exported clip $($index + 1) has unexpected duration $($duration)."
        }
    }
    if ((Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4').Count -ne 2) {
        throw 'The UI exported an excluded clip or failed to export all selected clips.'
    }
    if ((Get-FileHash $source -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'The source hash changed during the UI workflow.'
    }

    $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $progressWindow = Wait-Window 'RightClip working' -timeoutSeconds 10
    $deadline = [DateTime]::UtcNow.AddSeconds($exportTimeoutSeconds)
    do {
        $closeApp = Find-AutomationElement -Parent $progressWindow -AutomationId 'OperationResultCloseApp'
        if ($closeApp -and -not $closeApp.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $closeApp -or $closeApp.Current.IsOffscreen) {
        throw 'The writing window did not offer Close app after writing.'
    }
    $closeApp.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) {
        throw 'Close app did not close the worker cleanly.'
    }

    $process = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"") -PassThru
    $window = Wait-Window 'RightClip'
    $mainHandle = [IntPtr]$window.Current.NativeWindowHandle
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $export = Find-AutomationElement -Parent $window -AutomationId 'ExportTimelineClips'
        if ($export -and $export.Current.IsEnabled) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $export -or -not $export.Current.IsEnabled) {
        throw 'The skip-notification test video did not load.'
    }
    $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $progressWindow = Wait-Window 'RightClip working' -timeoutSeconds 10
    $progressState = $progressWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if ($progressWindow.Current.IsOffscreen -or $progressState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'The writing window was not visibly normal while the editor was hidden.'
    }
    if ([RightClipUiCapture]::IsWindowVisible($mainHandle)) {
        throw 'The editor was visible during the skip-notification export.'
    }
    $skip = Find-AutomationElement -Parent $progressWindow -AutomationId 'SkipCompletionNotification'
    $skip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    if ($skip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
        [System.Windows.Automation.ToggleState]::On) {
        throw 'Skip notification could not be enabled during writing.'
    }
    if (-not $process.WaitForExit($exportTimeoutSeconds * 1000)) {
        throw 'Skip notification did not close RightClip after the operation completed.'
    }
    if ($process.ExitCode -ne 0) {
        throw "The skip-notification worker failed with exit code $($process.ExitCode)."
    }
    $savedSettings = Get-Content -LiteralPath $env:RIGHTCLIP_SETTINGS_PATH -Raw | ConvertFrom-Json
    if (-not $savedSettings.SuppressCompletionNotification) {
        throw 'Skip notification was not saved as the application default.'
    }

    $process = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"") -PassThru
    $window = Wait-Window 'RightClip'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $export = Find-AutomationElement -Parent $window -AutomationId 'ExportTimelineClips'
        if ($export -and $export.Current.IsEnabled) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $export -or -not $export.Current.IsEnabled) {
        throw 'The default-notification test video did not load.'
    }
    $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $progressWindow = Wait-Window 'RightClip working' -timeoutSeconds 10
    $skip = Find-AutomationElement -Parent $progressWindow -AutomationId 'SkipCompletionNotification'
    if ($skip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
        [System.Windows.Automation.ToggleState]::On) {
        throw 'The saved skip-notification default was not applied to a new worker.'
    }
    if (-not $process.WaitForExit($exportTimeoutSeconds * 1000)) {
        throw 'The saved skip-notification default did not close the new worker after writing.'
    }
    if ($process.ExitCode -ne 0) {
        throw "The default skip-notification worker failed with exit code $($process.ExitCode)."
    }

    # Skip notification would close a successful write before Hide could be clicked.
    Set-Content -LiteralPath $env:RIGHTCLIP_SETTINGS_PATH -Value '{"SceneSensitivity":60,"SuppressCompletionNotification":false}' -Encoding utf8
    # A denied-folder failure finishes before UI Automation can click Hide. This stand-in keeps the
    # working window up, then fails, so Hide is armed before the failed result arrives.
    $stubRoot = Join-Path $work 'failing-ffmpeg'
    $stubProject = Join-Path $stubRoot 'project'
    $stubTools = Join-Path $stubRoot 'tools'
    New-Item -ItemType Directory -Force -Path $stubProject | Out-Null
    @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <PublishSingleFile>true</PublishSingleFile>
    <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
    <AssemblyName>ffmpeg</AssemblyName>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
    <DebugType>none</DebugType>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $stubProject 'ffmpeg.csproj') -Encoding utf8
    @'
using System;
using System.Threading;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length > 0 && string.Equals(args[0], "-version", StringComparison.Ordinal))
        {
            Console.WriteLine("ffmpeg version n7.1");
            Console.WriteLine("configuration: --enable-static --disable-gpl --pkg-config-flags=--static");
            return 0;
        }

        Thread.Sleep(TimeSpan.FromSeconds(4));
        Console.Error.WriteLine("simulated write failure");
        return 1;
    }
}
'@ | Set-Content -LiteralPath (Join-Path $stubProject 'Program.cs') -Encoding utf8
    & dotnet publish (Join-Path $stubProject 'ffmpeg.csproj') -c Release -o $stubTools --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not build the failing FFmpeg stand-in.'
    }
    $appDir = Split-Path -Parent $AppPath
    $script:realFfmpegPath = Join-Path $appDir 'ffmpeg.exe'
    $script:realFfmpegHash = (Get-FileHash -LiteralPath $script:realFfmpegPath -Algorithm SHA256).Hash
    $parkedFfmpeg = Join-Path $stubRoot 'real-ffmpeg.exe'
    Copy-Item -LiteralPath $script:realFfmpegPath -Destination $parkedFfmpeg -Force
    $parkedHash = (Get-FileHash -LiteralPath $parkedFfmpeg -Algorithm SHA256).Hash
    if ($parkedHash -ne $script:realFfmpegHash) {
        Remove-Item -LiteralPath $parkedFfmpeg -Force -ErrorAction SilentlyContinue
        throw 'Could not park a matching copy of the original FFmpeg binary.'
    }
    $script:parkedFfmpegPath = $parkedFfmpeg
    $env:RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG = '1'
    try {
        Copy-Item -LiteralPath (Join-Path $stubTools 'ffmpeg.exe') -Destination $script:realFfmpegPath -Force
        $failedHide = Start-LoadedEditor
        $clipsBeforeFailure = @(Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4').Count
        $failedHide.Export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Invoke-HideUntilExit -started $failedHide.Process -editor $failedHide.Window -reason 'after a failed write'
        if (@(Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4').Count -ne $clipsBeforeFailure) {
            throw 'Hide kept a clip from a write that should have failed.'
        }
    }
    finally {
        Remove-Item Env:RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG -ErrorAction SilentlyContinue
        try {
            Restore-RightClipFfmpeg
        }
        catch {
            # Keep the parked copy and let the outer finally retry. A terminating error here
            # would skip that retry and could also hide the UI failure that left the stand-in behind.
            $script:ffmpegRestoreError = $_.Exception.Message
        }
    }
    if ($script:parkedFfmpegPath) {
        try {
            Restore-RightClipFfmpeg
        }
        catch {
            throw "Could not restore the original FFmpeg binary after the failed-write test. $($script:ffmpegRestoreError) $($_.Exception.Message)"
        }
    }

    $clipsBeforeSuccess = @(Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4').Count
    $successfulHide = Start-LoadedEditor
    $successfulHide.Export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Invoke-HideUntilExit -started $successfulHide.Process -editor $successfulHide.Window -reason 'after a successful write'
    $clipDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $clipCount = @(Get-ChildItem -LiteralPath $work -Filter '*.clip*.mp4').Count
        if ($clipCount -gt $clipsBeforeSuccess) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $clipDeadline)
    if ($clipCount -le $clipsBeforeSuccess) {
        throw 'Hide exited without leaving the successful clip on disk.'
    }

    $beta = Join-Path $work 'beta-video.mp4'
    Copy-Item -LiteralPath $source -Destination $beta -Force
    $launcher = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"", '--path', "`"$beta`"") -PassThru
    if (-not $launcher.WaitForExit(15000)) {
        if (-not $launcher.HasExited) { $launcher.Kill() }
        throw 'The two-path launcher did not exit.'
    }
    if ($launcher.ExitCode -ne 0) {
        throw "The two-path launcher exited with code $($launcher.ExitCode)."
    }
    $matched = @{}
    $seenWorkers = @{}
    $launchDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $candidates = @(Get-CimInstance Win32_Process -Filter "Name = 'RightClip.exe'" | Where-Object { $_.CommandLine })
        foreach ($candidate in $candidates) {
            if ($candidate.ProcessId -eq $launcher.Id) { continue }
            $ownsSource = $candidate.CommandLine.Contains($source) -and -not $candidate.CommandLine.Contains($beta)
            $ownsBeta = $candidate.CommandLine.Contains($beta) -and -not $candidate.CommandLine.Contains($source)
            if (-not $ownsSource -and -not $ownsBeta) { continue }
            if (-not $seenWorkers.ContainsKey($candidate.ProcessId)) {
                $seenWorkers[$candidate.ProcessId] = $true
                $workerProcess = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
                if ($workerProcess) { $childProcesses += $workerProcess }
            }
            if ($ownsSource) { $matched[$source] = $candidate.ProcessId }
            if ($ownsBeta) { $matched[$beta] = $candidate.ProcessId }
        }
        if ($matched.Count -eq 2) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $launchDeadline)
    if ($matched.Count -ne 2) {
        $lines = @($candidates | ForEach-Object { $_.CommandLine }) -join ' || '
        throw "A two-path launch did not start one worker per video. Workers: $lines"
    }
    foreach ($path in @($source, $beta)) {
        $worker = $childProcesses | Where-Object { $_.Id -eq $matched[$path] } | Select-Object -First 1
        if (-not $worker) {
            throw "The worker process for $path disappeared before its window could be checked."
        }
        $editor = Wait-Window 'RightClip' -worker $worker
        $expectedName = [System.IO.Path]::GetFileName($path)
        $shown = ''
        $nameDeadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $label = Find-AutomationElement -Parent $editor -AutomationId 'ActiveVideoSelection'
            if ($label) { $shown = $label.Current.Name }
            if ($shown -eq $expectedName) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $nameDeadline)
        if ($shown -ne $expectedName) {
            throw "The worker for $expectedName showed '$shown'."
        }
    }
    foreach ($worker in @($childProcesses)) {
        if ($worker -and -not $worker.HasExited) {
            $worker.CloseMainWindow() | Out-Null
        }
    }
    foreach ($worker in @($childProcesses)) {
        if ($worker -and -not $worker.HasExited -and -not $worker.WaitForExit(5000)) {
            $worker.Kill()
        }
    }

    $process = Start-Process -FilePath $appPath -ArgumentList @('--action', 'remove-metadata', '--path', "`"$source`"") -PassThru
    $window = Wait-Window 'RightClip - Remove Metadata'
    $metadataOutput = Join-Path $work 'source-without-metadata.mp4'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $status = Find-AutomationElement -Parent $window -AutomationId 'MetadataRemovalStatus'
        if ($status -and $status.Current.Name -eq 'Completed') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $results = Find-AutomationElement -Parent $window -AutomationId 'MetadataRemovalResults'
    $resultText = if ($results) { $results.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } else { '' }
    if (-not $status -or $status.Current.Name -ne 'Completed' -or
        -not $resultText.Contains("Completed file is in:$([Environment]::NewLine)$($metadataOutput)") -or
        -not (Test-Path -LiteralPath $metadataOutput)) {
        throw "Direct metadata removal did not complete automatically: $($resultText)"
    }
    $content = Find-AutomationElement -Parent $window -AutomationId 'MetadataRemovalContent'
    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    if (-not $content -or @($content.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition) |
            Where-Object { -not $_.Current.IsOffscreen }).Count -ne 0) {
        throw 'Direct metadata removal exposed application action buttons.'
    }
    if ((Get-FileHash $source -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'Direct metadata removal changed the original video.'
    }
    Write-Output "Inline preview resize, external time, hidden-editor writing, completion choices, saved skip-and-exit, clip export, Hide-and-exit, two-path launch, and metadata removal passed: $($work)"
}
finally {
    foreach ($running in @($process) + @($childProcesses)) {
        if ($null -eq $running -or $running.HasExited) { continue }
        $running.CloseMainWindow() | Out-Null
        if (-not $running.WaitForExit(5000)) {
            $running.Kill()
        }
    }
    Restore-RightClipFfmpeg
}
