<#
.SYNOPSIS
Provides window-only PNG capture for desktop automation.
.DESCRIPTION
Requires Windows, System.Drawing, and a visible, non-minimized window.
Captures the requested native window, never the surrounding desktop.
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Drawing
if (-not ('RightClipWindowCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RightClipWindowCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rectangle
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("dwmapi.dll")]
    public static extern int DwmFlush();

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr window, uint attribute,
        out Rectangle rectangle, int size);
}
'@
}

function Save-WindowScreenshot {
    <#
    .SYNOPSIS
    Saves a visible native window as a PNG and returns its pixel dimensions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $_ -ne [IntPtr]::Zero })]
        [IntPtr]$windowHandle,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$path
    )

    if (-not [RightClipWindowCapture]::IsWindowVisible($windowHandle) -or
        [RightClipWindowCapture]::IsIconic($windowHandle)) {
        throw 'A screenshot requires a visible, non-minimized window.'
    }

    $previousDpiContext = [RightClipWindowCapture]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    if ($previousDpiContext -eq [IntPtr]::Zero) {
        throw 'Windows could not set the screenshot thread DPI context.'
    }
    $bitmap = $null
    $cropped = $null
    $graphics = $null
    $deviceContext = [IntPtr]::Zero
    try {
        $rectangle = [RightClipWindowCapture+Rectangle]::new()
        if (-not [RightClipWindowCapture]::GetWindowRect($windowHandle, [ref]$rectangle)) {
            throw 'Windows could not read the capture window bounds.'
        }
        $width = $rectangle.Right - $rectangle.Left
        $height = $rectangle.Bottom - $rectangle.Top
        if ($width -lt 1 -or $height -lt 1) {
            throw 'The capture window has no drawable area.'
        }
        $flushResult = [RightClipWindowCapture]::DwmFlush()
        if ($flushResult -ne 0) {
            throw "Windows could not finish drawing the capture window (HRESULT $($flushResult))."
        }
        $bitmap = [Drawing.Bitmap]::new($width, $height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $deviceContext = $graphics.GetHdc()
        if (-not [RightClipWindowCapture]::PrintWindow($windowHandle, $deviceContext, 2)) {
            throw 'Windows could not capture the requested window.'
        }
        $graphics.ReleaseHdc($deviceContext)
        $deviceContext = [IntPtr]::Zero
        $frame = [RightClipWindowCapture+Rectangle]::new()
        if ([RightClipWindowCapture]::DwmGetWindowAttribute($windowHandle, 9, [ref]$frame, 16) -ne 0) {
            throw 'Windows could not read the visible capture frame.'
        }
        $left = [Math]::Max(0, $frame.Left - $rectangle.Left)
        $top = [Math]::Max(0, $frame.Top - $rectangle.Top)
        $right = [Math]::Min($width, $frame.Right - $rectangle.Left)
        $bottom = [Math]::Min($height, $frame.Bottom - $rectangle.Top)
        if ($right -le $left -or $bottom -le $top) { throw 'The visible capture frame is empty.' }
        $cropped = $bitmap.Clone([Drawing.Rectangle]::new($left, $top, $right - $left, $bottom - $top),
            [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $cropped.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        [pscustomobject]@{ Width = $cropped.Width; Height = $cropped.Height }
    }
    finally {
        if ($deviceContext -ne [IntPtr]::Zero) {
            $graphics.ReleaseHdc($deviceContext)
        }
        if ($graphics) { $graphics.Dispose() }
        if ($cropped) { $cropped.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        [RightClipWindowCapture]::SetThreadDpiAwarenessContext($previousDpiContext) | Out-Null
    }
}
