<#
.SYNOPSIS
Downloads hash-pinned static LGPL FFmpeg tools and their matching source.
.DESCRIPTION
Requires PowerShell 7 on Windows and network access on an empty cache.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$destination = (Join-Path (Split-Path $PSScriptRoot -Parent) 'third_party\ffmpeg\tools')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content (Join-Path $PSScriptRoot 'ffmpeg.json') -Raw | ConvertFrom-Json
$cache = Join-Path $root 'third_party\ffmpeg'
New-Item -ItemType Directory -Force $cache | Out-Null
New-Item -ItemType Directory -Force $Destination | Out-Null

function Get-PinnedFile {
    <#
    .SYNOPSIS
    Returns a cached download only after checking its SHA-256 pin.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNull()]$record)

    $path = Join-Path $cache $Record.file
    if (-not (Test-Path $path)) {
        $download = "$path.download"
        Write-Verbose "Downloading $($Record.url)"
        Invoke-WebRequest -Uri $Record.url -OutFile $download
        Move-Item $download $path -Force
    }

    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($actual -ne $Record.sha256) {
        throw "$($Record.file) has SHA-256 $actual; expected $($Record.sha256). Remove the stale file and review the pin before updating it."
    }

    return $path
}

$binaryArchive = Get-PinnedFile $manifest.binary
$sourceArchive = Get-PinnedFile $manifest.source
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($binaryArchive)
try {
    foreach ($tool in @('ffmpeg.exe', 'ffprobe.exe')) {
        $entryName = "$($manifest.binary.root)/bin/$tool"
        $entry = $archive.Entries | Where-Object FullName -eq $entryName
        if ($null -eq $entry -or @($entry).Count -ne 1) {
            throw "The FFmpeg archive does not contain exactly one $entryName entry."
        }

        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Destination $tool), $true)
    }

    $licenseEntry = $archive.Entries | Where-Object FullName -eq "$($manifest.binary.root)/LICENSE.txt"
    if ($null -eq $licenseEntry -or @($licenseEntry).Count -ne 1) {
        throw 'The FFmpeg archive has no license text.'
    }

    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($licenseEntry, (Join-Path $Destination 'COPYING.LGPLv3'), $true)
}
finally {
    $archive.Dispose()
}

$ffmpeg = Join-Path $Destination 'ffmpeg.exe'
$version = (& $ffmpeg -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg -version failed: $version"
}

foreach ($flag in @('--enable-gpl', '--enable-nonfree', '--enable-libx264', '--enable-libx265', '--enable-shared')) {
    if ($version.Contains($flag)) {
        throw "The pinned FFmpeg build contains prohibited option $flag."
    }
}

if (-not $version.Contains('--enable-static') -and -not $version.Contains('--pkg-config-flags=--static')) {
    throw 'The pinned FFmpeg build is not configured for static linking.'
}

if (-not $version.Contains($manifest.version) -or -not $version.Contains($manifest.commit.Substring(0, 10))) {
    throw "The downloaded binaries do not match pinned version $($manifest.version)."
}

Add-Type -AssemblyName System.Formats.Tar
Add-Type -AssemblyName System.IO.Compression
$sourceStream = [System.IO.File]::OpenRead($sourceArchive)
$gzip = [System.IO.Compression.GZipStream]::new($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
$reader = [System.Formats.Tar.TarReader]::new($gzip)
$licenses = @('COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'COPYING.GPLv3')
$found = @{}
try {
    while ($entry = $reader.GetNextEntry()) {
        foreach ($license in $licenses) {
            if ($entry.Name -eq "$($manifest.source.root)/$license") {
                $output = [System.IO.File]::Create((Join-Path $Destination $license))
                try {
                    $entry.DataStream.CopyTo($output)
                }
                finally {
                    $output.Dispose()
                }
                $found[$license] = $true
            }
        }
    }
}
finally {
    $reader.Dispose()
    $gzip.Dispose()
    $sourceStream.Dispose()
}
foreach ($license in $licenses) {
    if (-not $found.ContainsKey($license)) {
        throw "The matching FFmpeg source is missing $license."
    }
}

Copy-Item $sourceArchive (Join-Path $Destination 'ffmpeg-source.tar.gz') -Force
$buildRecord = @(
    "RightClip pinned FFmpeg: $($manifest.version)",
    "Matching source commit: $($manifest.commit)",
    "Binary archive: $($manifest.binary.url)",
    "Binary SHA-256: $($manifest.binary.sha256)",
    "Source archive: $($manifest.source.url)",
    "Source SHA-256: $($manifest.source.sha256)",
    '',
    $version
)
Set-Content -Path (Join-Path $Destination 'FFmpeg-Build.txt') -Value $buildRecord -Encoding utf8
Write-Output "Verified static LGPL FFmpeg tools in $($Destination)"
