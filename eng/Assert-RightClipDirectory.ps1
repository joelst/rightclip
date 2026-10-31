<#
.SYNOPSIS
Provides shared install/uninstall directory safety validation.
.DESCRIPTION
Dot-source this file from the portable installer or uninstaller.
Rejects roots, links, unrelated non-empty directories, and out-of-place uninstall.
#>
[CmdletBinding()]
param()

function Assert-RightClipDirectory {
    <#
    .SYNOPSIS
    Returns a normalized RightClip directory only after safety checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$directory,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$operation,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$payloadDirectory
    )

    $target = [IO.Path]::GetFullPath($directory).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($target).TrimEnd('\')
    if ($target -eq $root -or (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw 'Choose a normal installation folder, not a drive root or a file.'
    }

    $ancestor = $target
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Installation paths must not contain symbolic links or junctions.'
            }
        }
        $ancestor = Split-Path $ancestor -Parent
    }

    if (Test-Path -LiteralPath $target -PathType Container) {
        $entries = @(Get-ChildItem -LiteralPath $target -Force)
        $existing = (Test-Path -LiteralPath (Join-Path $target 'RightClip.exe') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $target 'RightClip.Shell.dll') -PathType Leaf)
        if ($entries.Count -gt 0 -and -not $existing) {
            throw 'Choose an empty folder or an existing RightClip installation.'
        }
        if (Get-ChildItem -LiteralPath $target -Recurse -Force |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw 'The installation contains links or junctions; remove them before continuing.'
        }
    }

    if ($operation -eq 'Uninstall') {
        $payload = [IO.Path]::GetFullPath($payloadDirectory).TrimEnd('\')
        if ($target -ne $payload -or
            -not (Test-Path -LiteralPath (Join-Path $target 'RightClip.Shell.dll') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $target 'Uninstall-RightClip.ps1') -PathType Leaf)) {
            throw 'Run the uninstaller from the RightClip installation it is removing.'
        }
    }

    return $target
}
