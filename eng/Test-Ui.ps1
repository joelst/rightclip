<#
.SYNOPSIS
Exercises the actual trim editor, timeline preview, review, and output write.
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
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root "TestResults\ui-smoke\$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$source = Join-Path $work 'source.mp4'
if ($MediaPath) {
    Copy-Item $MediaPath $source
}
else {
    $ffmpeg = Join-Path (Split-Path $AppPath -Parent) 'ffmpeg.exe'
    & $ffmpeg -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=320x240:rate=25:duration=4' `
        -f lavfi -i 'sine=frequency=440:duration=4' -c:v mpeg4 -g 25 -c:a aac $source
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate the UI smoke-test fixture.'
    }
}
$sourceHash = (Get-FileHash $source -Algorithm SHA256).Hash
$process = Start-Process -FilePath $AppPath -ArgumentList @('--action', 'trim', '--path', "`"$source`"") -PassThru

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

try {
    $window = Wait-Window 'RightClip'
    $editCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $review = Find-NamedElement $window 'Review and run' ([System.Windows.Automation.ControlType]::Button)
        $edits = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        if ($review -and $review.Current.IsEnabled -and $edits.Count -ge 2) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $review -or -not $review.Current.IsEnabled -or $edits.Count -lt 2) {
        throw 'The trim editor did not become ready.'
    }

    $startValue = $edits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $sliderCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'StartCutSlider')
    $startSlider = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $sliderCondition)
    if (-not $startSlider) {
        throw 'The start-cut timeline slider was not found.'
    }
    $startSlider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue(1)
    if ($startValue.Current.Value -ne '1') {
        throw "The timeline produced '$($startValue.Current.Value)' instead of '1'."
    }
    $previewCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, ('source.mp4 {0} 00:00:01.000' -f [char]0x00b7)),
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
    $review.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $reviewWindow = Wait-Window 'Review RightClip outputs'
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    $text = $reviewWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition) |
        ForEach-Object { $_.Current.Name }
    if ($text -notcontains ('Keyframe-safe re-encode {0} one new sibling file' -f [char]0x00b7)) {
        throw 'The trim review did not describe the default keyframe-safe re-encode.'
    }
    if (-not ($text -match 'landed 00:00:01.000')) {
        throw "The review did not show the expected landed keyframe. $($text -join ' | ')"
    }

    $write = Find-NamedElement $reviewWindow 'Write new files' ([System.Windows.Automation.ControlType]::Button)
    $write.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $output = Join-Path $work 'source.trimmed.mp4'
    $ffprobe = Join-Path (Split-Path $AppPath -Parent) 'ffprobe.exe'
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $probeSucceeded = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $output) {
            $probeOutput = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 $output 2>$null
            if ($LASTEXITCODE -eq 0) {
                $probeSucceeded = $true
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $probeSucceeded) {
        throw 'FFmpeg did not finish a readable UI-generated output in time.'
    }
    if ((Get-FileHash $source -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'The source hash changed during the UI workflow.'
    }
    $probeOutput
    Write-Output "UI review-and-write smoke test passed: $($output)"
}
finally {
    if (-not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
        }
    }
}
