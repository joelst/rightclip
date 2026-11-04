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

    public static void SendRightArrow(IntPtr window, bool down)
    {
        var data = 1u | (MapVirtualKey(0x27, 0) << 16) | (1u << 24) | (down ? 0u : 0xc0000000u);
        SendMessage(window, down ? 0x100u : 0x101u, (IntPtr)0x27, (IntPtr)(long)data);
    }
}
'@
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root "TestResults\ui-smoke\$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$env:RIGHTCLIP_SETTINGS_PATH = Join-Path $work 'settings.json'
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
$otherSource = Join-Path $work 'other.mp4'
Copy-Item -LiteralPath $source -Destination $otherSource
$exportTimeoutSeconds = 45
$process = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"", '--path', "`"$otherSource`"") -PassThru

function Wait-Window {
    <#
    .SYNOPSIS
    Waits for a window belonging to the test worker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$name, [ValidateRange(1, 300)][int]$timeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($window) {
            return $window
        }
        $errorCondition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RightClip could not start'),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id))
        $errorWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $errorCondition)
        if ($errorWindow) {
            $message = $errorWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text)) | ForEach-Object { $_.Current.Name }
            throw ($message -join ' | ')
        }
        if ($process.HasExited) {
            throw "RightClip exited with code $($process.ExitCode) before opening $Name."
        }
        Start-Sleep -Milliseconds 200
    }
    $processCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
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
    $selectedVideos = $activeVideo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    if ($selectedVideos.Count -ne 1 -or $selectedVideos[0].Current.Name -ne 'source.mp4') {
        throw "The Explorer-provided video was not selected automatically. Selection: $($selectedVideos.Count), $($selectedVideos | ForEach-Object { $_.Current.Name })"
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

    $activeVideo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $otherVideo = Find-NamedElement -Parent $activeVideo -Name 'other.mp4' -ControlType ([System.Windows.Automation.ControlType]::ListItem)
    $otherVideo.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $activeVideo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
    (Find-NamedElement -Parent $window -Name 'Remove' -ControlType ([System.Windows.Automation.ControlType]::Button)).
        GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $selection = $activeVideo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        if ($selection.Count -eq 1 -and $selection[0].Current.Name -eq 'source.mp4' -and $export.Current.IsEnabled) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($selection.Count -ne 1 -or $selection[0].Current.Name -ne 'source.mp4' -or -not $export.Current.IsEnabled -or
        -not (Find-AutomationElement -Parent $window -AutomationId 'TimelineClip1')) {
        throw 'Removing the active file did not select the remaining video and restore its exportable timeline.'
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
    $firstCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    if (-not $firstCut -or [Math]::Abs(
            $firstCut.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value - $firstPosition) -gt 0.05) {
        throw 'The context menu did not add its cut at the selected timeline position.'
    }
    $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ((Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1') -or
        (Find-AutomationElement -Parent $window -AutomationId 'TimelineClip2')) {
        throw 'Reset cuts did not restore a single full-length piece.'
    }
    $precisionPosition = [Math]::Round($sourceDuration / 7, 7)
    $range.SetValue($precisionPosition)
    $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $precisionCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
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
        (Find-AutomationElement -Parent $window -AutomationId "TimelineClip$_").Current.BoundingRectangle
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
    $previewCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, ('source.mp4 {0} {1}' -f [char]0x00b7, $previewTime)),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text))
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $preview = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $previewCondition)
        if ($preview) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $preview) {
        throw 'The timeline did not render the expected video frame.'
    }

    $assertTrimContentVisible = {
        $tabs = Find-AutomationElement -Parent $window -AutomationId 'TrimTabs'
        $trimAdvanced = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
        foreach ($element in @($add, $position, $trimAdvanced)) {
            if (-not $element -or $element.Current.IsOffscreen -or
                $element.Current.BoundingRectangle.Bottom -gt $tabs.Current.BoundingRectangle.Bottom) {
                throw 'A Trim control is clipped by the tab boundary.'
            }
        }
    }
    $bounds = $window.Current.BoundingRectangle
    $assertAdvancedContentVisible = {
        $advancedOptions = Find-AutomationElement -Parent $window -AutomationId 'AdvancedTrimOptions'
        $expansion = $advancedOptions.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expansion.Expand()
        Start-Sleep -Milliseconds 250
        $batchReview = Find-NamedElement -Parent $window -Name 'Review batch / scene operation' -ControlType ([System.Windows.Automation.ControlType]::Button)
        $scrollItem = $null
        if ($batchReview.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
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
        if ($batchReview.Current.IsOffscreen -or $batchReview.Current.BoundingRectangle.Height -lt 10 -or
            $batchReview.Current.BoundingRectangle.Bottom -gt $tabs.Current.BoundingRectangle.Bottom) {
            throw 'Expanded Advanced controls cannot scroll the batch-review button into the tab.'
        }
        $expansion.Collapse()
    }
    foreach ($element in @($add, $position, $export)) {
        $elementBounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $elementBounds.Height -lt 10 -or $elementBounds.Bottom -gt $bounds.Bottom) {
            throw 'A primary timeline control is clipped or requires scrolling.'
        }
    }
    & $assertTrimContentVisible
    & $assertAdvancedContentVisible
    $transform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $scale = $bounds.Width / 1080
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
        $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $errorWindow = Wait-Window 'RightClip result' -timeoutSeconds 10
        $ok = Find-AutomationElement -Parent $errorWindow -AutomationId 'OperationResultClose'
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
    $firstCut = Find-AutomationElement -Parent $window -AutomationId 'TimelineCut1'
    $firstCut.SetFocus()
    $firstPosition += 0.32
    try {
        for ($repeat = 0; $repeat -lt 8; $repeat++) { [RightClipUiCapture]::SendRightArrow($mainHandle, $true) }
        $export.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    finally { [RightClipUiCapture]::SendRightArrow($mainHandle, $false) }
    $resultWindow = Wait-Window 'RightClip result' -timeoutSeconds $exportTimeoutSeconds
    $resultState = $resultWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if ($resultWindow.Current.IsOffscreen -or $resultState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'The operation result was not visibly normal while the base window was minimized.'
    }
    $baseWindowState = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if (-not $window.Current.IsOffscreen -and $baseWindowState -ne [System.Windows.Automation.WindowVisualState]::Minimized) {
        throw 'The base window was neither hidden nor minimized while the operation result was shown.'
    }
    $resultSummary = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationResultSummary'
    if (-not $resultSummary.Current.Name.Contains('2 new outputs')) {
        throw "The completion result did not report both outputs: $($resultSummary.Current.Name)"
    }
    $closeResult = Find-AutomationElement -Parent $resultWindow -AutomationId 'OperationResultClose'
    $closeResult.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
    $baseWindowState = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if ($window.Current.IsOffscreen -or $baseWindowState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'The base window did not return to its normal state after the result was closed.'
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
    $progressState = $progressWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState
    if ($progressWindow.Current.IsOffscreen -or $progressState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'The operation window was not visibly normal while the base window was minimized.'
    }
    $hide = Find-AutomationElement -Parent $progressWindow -AutomationId 'HideOperationProgress'
    $mainHandle = [IntPtr]$window.Current.NativeWindowHandle
    $progressHandle = [IntPtr]$progressWindow.Current.NativeWindowHandle
    $hide.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 200
    if ([RightClipUiCapture]::IsWindowVisible($mainHandle) -or [RightClipUiCapture]::IsWindowVisible($progressHandle)) {
        throw 'Hide left the editor or progress window visible, including in the taskbar.'
    }
    if (-not $process.WaitForExit($exportTimeoutSeconds * 1000)) {
        throw 'Hide did not hide the windows and exit after the operation completed.'
    }
    if ($process.ExitCode -ne 0) {
        throw "The hidden worker failed with exit code $($process.ExitCode)."
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
    Write-Output "Active-file removal, immediate/held keyboard edits, export while a key is held, folder-denial retry, clip export, and metadata removal passed: $($work)"
}
finally {
    if (-not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
        }
    }
}
