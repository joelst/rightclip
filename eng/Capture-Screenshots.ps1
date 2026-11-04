<#
.SYNOPSIS
Captures the main RightClip app workflows for documentation.
.DESCRIPTION
Requires PowerShell 7, an unlocked interactive Windows desktop, and a published
RightClip app with its bundled FFmpeg tools. Uses UI Automation and window-only
capture, generated sample media, and isolated settings. Does not install or
register anything. Each run creates a new output folder with PNGs, a contact
sheet, and a JSON caption manifest. Temporary media and workers are cleaned up.
.EXAMPLE
pwsh -File .\eng\Capture-Screenshots.ps1
.EXAMPLE
pwsh -File .\eng\Capture-Screenshots.ps1 -OutputDirectory .\docs\images
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$appPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip\RightClip.exe'),
    [ValidateNotNullOrEmpty()]
    [string]$outputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestResults\documentation-screenshots')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or -not [Environment]::UserInteractive) {
    throw 'Screenshot capture requires an interactive Windows desktop.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $PSScriptRoot 'Save-WindowScreenshot.ps1')

function Find-CaptureElement {
    <#
    .SYNOPSIS
    Finds a descendant by automation ID or accessible name and optional type.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Id')]
    param(
        [Parameter(Mandatory = $true)]$parent,
        [Parameter(Mandatory = $true, ParameterSetName = 'Id')]
        [ValidateNotNullOrEmpty()][string]$automationId,
        [Parameter(Mandatory = $true, ParameterSetName = 'Name')]
        [ValidateNotNullOrEmpty()][string]$name,
        [System.Windows.Automation.ControlType]$controlType
    )

    $property = [System.Windows.Automation.AutomationElement]::AutomationIdProperty
    $value = $automationId
    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        $property = [System.Windows.Automation.AutomationElement]::NameProperty
        $value = $name
    }
    $condition = [System.Windows.Automation.PropertyCondition]::new($property, $value)
    if ($controlType) {
        $condition = [System.Windows.Automation.AndCondition]::new($condition,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $controlType))
    }
    $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-CaptureEditor {
    <#
    .SYNOPSIS
    Waits until modal dialogs and pending operations release the editor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$process,
        [Parameter(Mandatory = $true)]$window
    )

    $editor = $window
    Wait-CaptureState -Process $process -Description 'loaded, idle editor' -Condition {
        if (-not $editor.Current.IsEnabled -or $editor.Current.IsOffscreen) { return $false }
        $loading = Find-CaptureElement -Parent $editor -AutomationId 'LoadingIndicator'
        $button = Find-CaptureElement -Parent $editor -AutomationId 'ExportTimelineClips'
        if (-not $button -or $button.Current.IsOffscreen) {
            $button = Find-CaptureElement -Parent $editor -Name 'Review and run' -ControlType ([System.Windows.Automation.ControlType]::Button)
        }
        $button -and $button.Current.IsEnabled -and (-not $loading -or $loading.Current.IsOffscreen)
    } | Out-Null
}

function Wait-CaptureState {
    <#
    .SYNOPSIS
    Waits for an observable app state, failing explicitly on exit or timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$process,
        [Parameter(Mandatory = $true)][scriptblock]$condition,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$description,
        [ValidateRange(1, 300)][int]$timeoutSeconds = 90
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    do {
        if ($process.HasExited) {
            throw "RightClip exited with code $($process.ExitCode) while waiting for $($description)."
        }
        try {
            $result = & $condition
            if ($result) { return $result }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            Write-Verbose "The UI was rebuilt while waiting for $($description); retrying."
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $ownedWindows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
    $details = foreach ($ownedWindow in $ownedWindows) {
        $ownedWindow.Current.Name
        $ownedWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)) |
            ForEach-Object { $_.Current.Name }
    }
    throw "Timed out waiting for $($description). Open UI: $($details -join ' | ')"
}

function Wait-CaptureWindow {
    <#
    .SYNOPSIS
    Waits for a named top-level window owned by the launched worker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$process,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$name
    )

    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $windowCondition = [System.Windows.Automation.AndCondition]::new($processCondition,
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $name),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
    Wait-CaptureState -Process $process -Description "window '$($name)'" -Condition {
        $roots = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $processCondition)
        foreach ($candidate in $roots) {
            if ($candidate.Current.Name -eq $name -and
                $candidate.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) { return $candidate }
            $owned = $candidate.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $windowCondition)
            if ($owned) { return $owned }
        }
    }
}

function Invoke-CaptureButton {
    <#
    .SYNOPSIS
    Invokes an enabled button through UI Automation without sending keystrokes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$element)

    if (-not $element.Current.IsEnabled) {
        throw "The capture button is disabled: $($element.Current.Name)"
    }
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-CaptureOption {
    <#
    .SYNOPSIS
    Selects an item in a WPF combo box by accessible name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$element,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$name
    )

    $expansion = $element.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expansion.Expand()
    try {
        $item = Find-CaptureElement -Parent $element -Name $name
        if (-not $item) { throw "The capture option was not found: $($name)" }
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    finally {
        if ($expansion.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) {
            $expansion.Collapse()
        }
    }
}

function Invoke-CaptureAdvancedScroll {
    <#
    .SYNOPSIS
    Scrolls the constrained Advanced controls to a reproducible position.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$window,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][double]$percent,
        [string[]]$requiredAutomationIds = @()
    )

    $advanced = Find-CaptureElement -Parent $window -AutomationId 'AdvancedTrimOptions'
    $advanced.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty, $true)
    $viewer = $advanced.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $viewer) { throw 'The Advanced scroll viewer was not found.' }
    $scroll = $viewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $scroll.SetScrollPercent(-1, $percent)
    Start-Sleep -Milliseconds 150
    if ($requiredAutomationIds.Count -gt 0) {
        $bounds = $viewer.Current.BoundingRectangle
        $targets = @($requiredAutomationIds | ForEach-Object {
            $target = Find-CaptureElement -Parent $window -AutomationId $_
            if (-not $target) { throw "The Advanced capture control was not found: $($_)" }
            $target.Current.BoundingRectangle
        })
        $first = ($targets.Top | Measure-Object -Minimum).Minimum
        $last = ($targets.Bottom | Measure-Object -Maximum).Maximum
        if ($last - $first -gt $bounds.Height - 4) {
            throw 'The Advanced capture controls do not fit in the viewport.'
        }
        $delta = if ($first -lt $bounds.Top + 2) { $first - $bounds.Top - 2 }
            elseif ($last -gt $bounds.Bottom - 2) { $last - $bounds.Bottom + 2 }
            else { 0 }
        if ($delta -ne 0) {
            $state = $scroll.Current
            $scrollableHeight = $bounds.Height * (100 - $state.VerticalViewSize) / $state.VerticalViewSize
            $targetPercent = [Math]::Clamp($state.VerticalScrollPercent + 100 * $delta / $scrollableHeight, 0, 100)
            $scroll.SetScrollPercent(-1, $targetPercent)
            Start-Sleep -Milliseconds 150
        }
    }
    foreach ($id in $requiredAutomationIds) {
        $element = Find-CaptureElement -Parent $window -AutomationId $id
        $bounds = $viewer.Current.BoundingRectangle
        if (-not $element -or $element.Current.IsOffscreen -or
            $element.Current.BoundingRectangle.Top -lt $bounds.Top -or
            $element.Current.BoundingRectangle.Bottom -gt $bounds.Bottom) {
            throw "The Advanced capture control is clipped: $($id)"
        }
    }
    if ($percent -eq 100) {
        $button = Find-CaptureElement -Parent $window -AutomationId 'BatchOperationReview'
        $tabs = Find-CaptureElement -Parent $window -AutomationId 'TrimTabs'
        if ($button.Current.IsOffscreen -or $button.Current.BoundingRectangle.Bottom -gt $tabs.Current.BoundingRectangle.Bottom) {
            throw 'The Advanced batch-review button is clipped in the capture layout.'
        }
    }
}

function Add-CaptureScreenshot {
    <#
    .SYNOPSIS
    Saves a numbered feature screenshot and records its caption and dimensions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$window,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$name,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$caption,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$directory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$entries
    )

    Start-Sleep -Milliseconds 150
    $file = '{0:00}-{1}.png' -f ($entries.Count + 1), $name
    $size = Save-WindowScreenshot -WindowHandle ([IntPtr]$window.Current.NativeWindowHandle) -Path (Join-Path $directory $file)
    $entries.Add([pscustomobject]@{ File = $file; Caption = $caption; Width = $size.Width; Height = $size.Height })
    Write-Verbose "Captured $($file)"
}

function Invoke-CaptureMediaGeneration {
    <#
    .SYNOPSIS
    Generates original postcard-style sample scenes, audio tracks, and subtitles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$directory,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ffmpeg
    )

    $scenes = @(
        @{ Title = 'COASTAL TRAIL'; Sky = '#96d6e5'; Horizon = '#197e97'; Land = '#164a55' },
        @{ Title = 'MOUNTAIN LIGHT'; Sky = '#182a48'; Horizon = '#506e8d'; Land = '#0c182b' },
        @{ Title = 'GOLDEN HOUR'; Sky = '#f6bc72'; Horizon = '#dc8359'; Land = '#613d53' }
    )
    $titleFont = [Drawing.Font]::new('Segoe UI', 32, [Drawing.FontStyle]::Bold)
    $labelFont = [Drawing.Font]::new('Segoe UI', 14)
    try {
        for ($index = 0; $index -lt $scenes.Count; $index++) {
            $scene = $scenes[$index]
            $bitmap = [Drawing.Bitmap]::new(960, 540)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $sky = [Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(0, 0), [Drawing.Point]::new(0, 540),
                [Drawing.ColorTranslator]::FromHtml($scene.Sky), [Drawing.ColorTranslator]::FromHtml($scene.Horizon))
            $land = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($scene.Land))
            try {
                $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $graphics.FillRectangle($sky, 0, 0, 960, 540)
                $graphics.FillEllipse([Drawing.Brushes]::LemonChiffon, 720, 155, 95, 95)
                $graphics.FillPolygon($land, [Drawing.Point[]]@(
                    [Drawing.Point]::new(0, 400), [Drawing.Point]::new(240, 235),
                    [Drawing.Point]::new(420, 400), [Drawing.Point]::new(680, 295),
                    [Drawing.Point]::new(960, 440), [Drawing.Point]::new(960, 540), [Drawing.Point]::new(0, 540)))
                $graphics.DrawString('RIGHTCLIP / SAMPLE FOOTAGE', $labelFont, [Drawing.Brushes]::White, 50, 42)
                $graphics.DrawString($scene.Title, $titleFont, [Drawing.Brushes]::White, 46, 75)
                $graphics.DrawString(('SCENE {0:00}  /  Originals stay unchanged' -f ($index + 1)),
                    $labelFont, [Drawing.Brushes]::White, 50, 478)
                $bitmap.Save((Join-Path $directory ('scene{0:00}.png' -f $index)), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally {
                $land.Dispose()
                $sky.Dispose()
                $graphics.Dispose()
                $bitmap.Dispose()
            }
        }
    }
    finally {
        $labelFont.Dispose()
        $titleFont.Dispose()
    }
    $playlist = Join-Path $directory 'scenes.txt'
    @("file 'scene00.png'", 'duration 10', "file 'scene01.png'", 'duration 10',
        "file 'scene02.png'", 'duration 10', "file 'scene02.png'") | Set-Content -LiteralPath $playlist
    $subtitles = Join-Path $directory 'Captions.en.srt'
    @'
1
00:00:00,000 --> 00:00:09,000
A walk along the coast.

2
00:00:10,000 --> 00:00:19,000
Finding a new perspective.

3
00:00:20,000 --> 00:00:29,000
The last light of the day.
'@ | Set-Content -LiteralPath $subtitles
    $metadata = Join-Path $directory 'chapters.ffmeta'
    @'
;FFMETADATA1
title=Coastal journey
artist=RightClip demo
comment=Generated sample media for documentation
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=Coastal trail
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=20000
title=Mountain light
[CHAPTER]
TIMEBASE=1/1000
START=20000
END=30000
title=Golden hour
'@ | Set-Content -LiteralPath $metadata
    $source = Join-Path $directory 'Coastal journey.mp4'
    & $ffmpeg -hide_banner -loglevel error -nostdin -n -f concat -safe 0 -i $playlist `
        -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=30' `
        -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=30' -i $subtitles -i $metadata `
        -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:s:0 -map_metadata 4 -map_chapters 4 `
        -vf 'scale=3840:2160' -r 24 -t 30 -c:v mpeg4 -q:v 5 -g 48 -pix_fmt yuv420p -c:a aac -c:s mov_text `
        -metadata:s:a:0 'title=Original sound' -metadata:s:a:0 'language=eng' `
        -metadata:s:a:1 'title=Commentary' -metadata:s:a:1 'language=eng' `
        -metadata:s:s:0 'title=English captions' -metadata:s:s:0 'language=eng' -movflags +faststart $source
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the documentation sample video.' }
    Copy-Item -LiteralPath $source -Destination (Join-Path $directory 'Weekend highlights.mp4')
    $source
}

function Invoke-CaptureOverviewGeneration {
    <#
    .SYNOPSIS
    Builds a labeled contact sheet from the captured windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$directory,
        [Parameter(Mandatory = $true)][Collections.Generic.List[object]]$entries
    )

    $columns = 4
    $cellWidth = 350
    $cellHeight = 270
    $bitmap = [Drawing.Bitmap]::new($columns * $cellWidth, [int][Math]::Ceiling($entries.Count / $columns) * $cellHeight)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = [Drawing.Font]::new('Segoe UI', 14, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(235, 239, 242))
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]
            $image = [Drawing.Image]::FromFile((Join-Path $directory $entry.File))
            try {
                $scale = [Math]::Min(330 / $image.Width, 225 / $image.Height)
                $left = ($index % $columns) * $cellWidth + 10
                $top = [Math]::Floor($index / $columns) * $cellHeight + 10
                $graphics.DrawImage($image, [Drawing.Rectangle]::new(
                    [int]($left + (330 - $image.Width * $scale) / 2), [int]$top,
                    [int]($image.Width * $scale), [int]($image.Height * $scale)))
                $graphics.DrawString(('{0:00}  {1}' -f ($index + 1), $entry.Caption), $font,
                    [Drawing.Brushes]::Black, [Drawing.RectangleF]::new($left, $top + 228, 330, 32))
            }
            finally { $image.Dispose() }
        }
        $bitmap.Save((Join-Path $directory 'overview.png'), [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $font.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$appPath = (Resolve-Path -LiteralPath $appPath).Path
$ffmpeg = Join-Path (Split-Path $appPath -Parent) 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf)) {
    throw 'Publish RightClip with its bundled FFmpeg tools before capturing screenshots.'
}
$runId = '{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
$captureDirectory = Join-Path ([IO.Path]::GetFullPath($outputDirectory)) $runId
$work = Join-Path (Split-Path $PSScriptRoot -Parent) ('TestResults\capture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $captureDirectory, $work -Force | Out-Null
$entries = [Collections.Generic.List[object]]::new()
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
try {
    $source = Invoke-CaptureMediaGeneration -Directory $work -FFmpeg $ffmpeg
    foreach ($workflow in @('trim', 'tracks', 'extract', 'details', 'remove-metadata')) {
        $action = if ($workflow -eq 'extract') { 'tracks' } else { $workflow }
        $startInfo = [Diagnostics.ProcessStartInfo]::new($appPath)
        $startInfo.UseShellExecute = $false
        $startInfo.Environment['RIGHTCLIP_SETTINGS_PATH'] = Join-Path $work 'settings.json'
        foreach ($argument in @('--action', $action, '--path', $source)) {
            $startInfo.ArgumentList.Add($argument)
        }
        if ($workflow -eq 'trim') {
            $startInfo.ArgumentList.Add('--path')
            $startInfo.ArgumentList.Add((Join-Path $work 'Weekend highlights.mp4'))
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $processes.Add($process)
        $title = if ($workflow -eq 'remove-metadata') { 'RightClip - Remove Metadata' } else { 'RightClip' }
        $window = Wait-CaptureWindow -Process $process -Name $title
        if ($workflow -eq 'remove-metadata') {
            Wait-CaptureState -Process $process -Description 'successful metadata removal' -Condition {
                $status = Find-CaptureElement -Parent $window -AutomationId 'MetadataRemovalStatus'
                $status -and $status.Current.Name -eq 'Completed'
            } | Out-Null
            Add-CaptureScreenshot -Window $window -Name 'remove-metadata' -Caption 'Remove Metadata' -Directory $captureDirectory -Entries $entries
        }
        else {
            Wait-CaptureEditor -Process $process -Window $window
            switch ($workflow) {
                'trim' {
                    Wait-CaptureState -Process $process -Description 'full video thumbnails' -Condition {
                        Find-CaptureElement -Parent $window -Name 'Full video timeline' -ControlType ([System.Windows.Automation.ControlType]::Text)
                    } | Out-Null
                    $scale = $window.Current.BoundingRectangle.Width / 1080
                    $transform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
                    $transform.Resize(1080 * $scale, 1000 * $scale)
                    Start-Sleep -Milliseconds 250
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'TimelineFit')
                    $position = Find-CaptureElement -Parent $window -AutomationId 'TimelinePosition'
                    foreach ($seconds in @(7.5, 18.75)) {
                        $position.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue($seconds)
                        Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'AddTimelineCut')
                    }
                    (Find-CaptureElement -Parent $window -AutomationId 'TimelineClip2').
                        GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
                    $position.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue(22)
                    $previewLabel = 'Coastal journey.mp4 {0} 00:00:22.000' -f [char]0x00b7
                    Wait-CaptureState -Process $process -Description 'selected preview frame' -Condition {
                        Find-CaptureElement -Parent $window -Name $previewLabel
                    } | Out-Null
                    Add-CaptureScreenshot -Window $window -Name 'trim-timeline' -Caption 'Select and export clips' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'TimelineZoomIn')
                    Add-CaptureScreenshot -Window $window -Name 'timeline-zoom' -Caption 'Zoom and pan the timeline' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'TimelineFit')
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'PopOutPreview')
                    $preview = Wait-CaptureWindow -Process $process -Name 'RightClip preview'
                    $preview.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Resize(800, 500)
                    Add-CaptureScreenshot -Window $preview -Name 'detached-preview' -Caption 'Resizable detached preview' -Directory $captureDirectory -Entries $entries
                    $preview.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -Name 'Settings' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    $settings = Wait-CaptureWindow -Process $process -Name 'RightClip settings'
                    Add-CaptureScreenshot -Window $settings -Name 'settings' -Caption 'FFmpeg and scene settings' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $settings -Name 'Cancel' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    Wait-CaptureEditor -Process $process -Window $window
                    $transform.Resize(850 * $scale, 700 * $scale)
                    Start-Sleep -Milliseconds 250
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'TimelineFit')
                    Add-CaptureScreenshot -Window $window -Name 'compact-editor' -Caption 'Compact timeline editor' -Directory $captureDirectory -Entries $entries
                    $transform.Resize(1080 * $scale, 1000 * $scale)
                    Start-Sleep -Milliseconds 250
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'TimelineFit')
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'PopOutPreview')
                    $advancedPreview = Wait-CaptureWindow -Process $process -Name 'RightClip preview'
                    Invoke-CaptureAdvancedScroll -Window $window -Percent 0 -RequiredAutomationIds 'CutEncoding'
                    Add-CaptureScreenshot -Window $window -Name 'encoding-options' -Caption 'Keyframe-safe and fast copy' -Directory $captureDirectory -Entries $entries
                    Select-CaptureOption -Element (Find-CaptureElement -Parent $window -AutomationId 'CutEncoding') -Name 'Fast stream copy'
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'ExportTimelineClips')
                    $review = Wait-CaptureWindow -Process $process -Name 'Review RightClip outputs'
                    Add-CaptureScreenshot -Window $review -Name 'fast-copy-review' -Caption 'Review landed keyframes' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $review -Name 'Cancel' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    Wait-CaptureEditor -Process $process -Window $window
                    Select-CaptureOption -Element (Find-CaptureElement -Parent $window -AutomationId 'CutEncoding') -Name 'Keyframe-safe (re-encode video)'
                    Select-CaptureOption -Element (Find-CaptureElement -Parent $window -AutomationId 'TrimMode') -Name 'Keep a range'
                    (Find-CaptureElement -Parent $window -AutomationId 'TrimStartInput').
                        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('3')
                    (Find-CaptureElement -Parent $window -AutomationId 'TrimEndInput').
                        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('24')
                    Invoke-CaptureAdvancedScroll -Window $window -Percent 50 -RequiredAutomationIds 'TrimMode', 'TrimStartInput', 'TrimEndInput'
                    Add-CaptureScreenshot -Window $window -Name 'batch-trimming' -Caption 'Advanced batch range trimming' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureAdvancedScroll -Window $window -Percent 100
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'BatchOperationReview')
                    $review = Wait-CaptureWindow -Process $process -Name 'Review RightClip outputs'
                    Add-CaptureScreenshot -Window $review -Name 'batch-review' -Caption 'Review every batch output' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $review -Name 'Cancel' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    Wait-CaptureEditor -Process $process -Window $window
                    Select-CaptureOption -Element (Find-CaptureElement -Parent $window -AutomationId 'TrimMode') -Name 'Split on scene changes'
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'BatchOperationReview')
                    $review = Wait-CaptureWindow -Process $process -Name 'Review RightClip outputs'
                    Add-CaptureScreenshot -Window $review -Name 'scene-review' -Caption 'Scene splitting and clip counts' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $review -Name 'Cancel' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    Wait-CaptureEditor -Process $process -Window $window
                    $advancedPreview.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
                    (Find-CaptureElement -Parent $window -AutomationId 'AdvancedTrimOptions').
                        GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -AutomationId 'ExportTimelineClips')
                    $progress = Wait-CaptureWindow -Process $process -Name 'RightClip working'
                    Wait-CaptureState -Process $process -Description 'active export progress' -Condition {
                        $file = Find-CaptureElement -Parent $progress -AutomationId 'OperationProgressFile'
                        $file -and $file.Current.Name -ne 'Preparing output files'
                    } | Out-Null
                    Add-CaptureScreenshot -Window $progress -Name 'export-progress' -Caption 'Export progress and notifications' -Directory $captureDirectory -Entries $entries
                    $result = Wait-CaptureWindow -Process $process -Name 'RightClip result'
                    $summary = Find-CaptureElement -Parent $result -AutomationId 'OperationResultSummary'
                    if (-not $summary.Current.Name.Contains('2 new outputs')) {
                        throw "The documentation export failed: $($summary.Current.Name)"
                    }
                    Add-CaptureScreenshot -Window $result -Name 'export-complete' -Caption 'Completed outputs' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $result -AutomationId 'OperationResultClose')
                }
                'tracks' {
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -Name 'Add subtitle file' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    $dialog = Wait-CaptureWindow -Process $process -Name 'Add soft subtitles'
                    $fileName = Wait-CaptureState -Process $process -Description 'subtitle file picker filename field' -Condition {
                        Find-CaptureElement -Parent $dialog -AutomationId '1148' -ControlType ([System.Windows.Automation.ControlType]::Edit)
                    }
                    $fileName.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue((Join-Path $work 'Captions.en.srt'))
                    Invoke-CaptureButton (Find-CaptureElement -Parent $dialog -AutomationId '1' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    Wait-CaptureState -Process $process -Description 'added subtitle row' -Condition {
                        Find-CaptureElement -Parent $window -Name 'Captions.en.srt'
                    } | Out-Null
                    Add-CaptureScreenshot -Window $window -Name 'audio-and-subtitles' -Caption 'Audio tracks and added subtitles' -Directory $captureDirectory -Entries $entries
                }
                'extract' {
                    (Find-CaptureElement -Parent $window -Name 'Extract selected soft subtitles instead of remuxing').
                        GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
                    Invoke-CaptureButton (Find-CaptureElement -Parent $window -Name 'Review and run' -ControlType ([System.Windows.Automation.ControlType]::Button))
                    $review = Wait-CaptureWindow -Process $process -Name 'Review RightClip outputs'
                    Add-CaptureScreenshot -Window $review -Name 'subtitle-extraction' -Caption 'Extract soft subtitles' -Directory $captureDirectory -Entries $entries
                    Invoke-CaptureButton (Find-CaptureElement -Parent $review -Name 'Cancel' -ControlType ([System.Windows.Automation.ControlType]::Button))
                }
                'details' {
                    foreach ($option in @('Fast start (MP4/MOV)', 'Strip location data')) {
                        (Find-CaptureElement -Parent $window -Name $option).
                            GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
                    }
                    Add-CaptureScreenshot -Window $window -Name 'video-details' -Caption 'Tags, chapters, and rotation' -Directory $captureDirectory -Entries $entries
                }
            }
            Wait-CaptureEditor -Process $process -Window $window
        }
        $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
        if (-not $process.WaitForExit(10000)) { throw "The $($workflow) worker did not close." }
    }
    Invoke-CaptureOverviewGeneration -Directory $captureDirectory -Entries $entries
    [ordered]@{
        AppVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($appPath).ProductVersion
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Media = 'Original generated sample scenes, two audio tracks, English soft subtitles, and three chapters.'
        Overview = 'overview.png'
        Screenshots = $entries.ToArray()
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $captureDirectory 'manifest.json')
    Write-Output "Captured $($entries.Count) app screenshots: $($captureDirectory)"
}
finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) {
            $process.CloseMainWindow() | Out-Null
            if (-not $process.WaitForExit(5000)) {
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)"
                foreach ($child in $children) {
                    $running = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
                    if ($running) { Stop-Process -Id $running.Id -Force }
                }
                Stop-Process -Id $process.Id -Force
                $process.WaitForExit()
            }
        }
        $process.Dispose()
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
