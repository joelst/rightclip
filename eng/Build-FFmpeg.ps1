<#
.SYNOPSIS
Builds RightClip's small static LGPL ffmpeg.exe and ffprobe.exe.
.DESCRIPTION
External libraries are zlib, openh264, kvazaar, libvpx, and libaom.
The script does not change eng/ffmpeg.json and does not approve redistribution.
Docker uses eng/ffmpeg/Dockerfile. Without Docker, WSL uses a relocatable
llvm-mingw toolchain because installing gcc-mingw needs root.
-VerifyOnly checks an existing pair and skips the compile.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$output = (Join-Path (Split-Path $PSScriptRoot -Parent) 'third_party\ffmpeg\own'),

    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root 'third_party\ffmpeg\src'
$toolchain = Join-Path $root 'third_party\ffmpeg\toolchain\llvm-mingw-20261104-ucrt-ubuntu-22.04-x86_64.tar.xz'
New-Item -ItemType Directory -Force -Path $output | Out-Null
if (-not $VerifyOnly) {
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $pinnedSource = Join-Path $root 'third_party\ffmpeg\ffmpeg-d838f9f9aeb0e09b4d068e2af20a46a12640696f.tar.gz'
    $cachedSource = Join-Path $cache 'ffmpeg-d838f9f9aeb0e09b4d068e2af20a46a12640696f.tar.gz'
    if ((Test-Path $pinnedSource) -and -not (Test-Path $cachedSource)) {
        Copy-Item $pinnedSource $cachedSource
    }
}

$log = Join-Path $output 'build.log'
if (Test-Path $log) {
    Remove-Item $log -Force
}

trap {
    Add-Content -Path $log -Value "BUILD_FAILED $($_.Exception.Message)"
    Write-Output "BUILD_FAILED $($_.Exception.Message)"
    exit 1
}

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$path)
    $converted = & wsl.exe -d Ubuntu -e wslpath -a $path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
        throw "wslpath failed for $path"
    }

    return $converted.Trim()
}

if (-not $VerifyOnly) {
    $cacheWsl = Convert-ToWslPath $cache
    $outputWsl = Convert-ToWslPath $output
    $logWsl = Convert-ToWslPath $log

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker version --format '{{.Server.Version}}' | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $imageContext = Join-Path $PSScriptRoot 'ffmpeg'
            & docker build -t rightclip-ffmpeg -f (Join-Path $imageContext 'Dockerfile') $imageContext
            if ($LASTEXITCODE -ne 0) {
                throw 'docker build failed.'
            }

            & docker run --rm -v "${cache}:/cache" -v "${output}:/out" rightclip-ffmpeg --cache /cache --output /out
            if ($LASTEXITCODE -ne 0) {
                throw 'docker ffmpeg build failed.'
            }
        }
    }

    if (-not (Test-Path (Join-Path $output 'ffmpeg.exe'))) {
        if (-not (Test-Path $toolchain)) {
            throw "Missing $toolchain. Download the pinned llvm-mingw archive before building without Docker."
        }

        $toolchainWsl = Convert-ToWslPath $toolchain
        $bootstrap = Convert-ToWslPath (Join-Path $PSScriptRoot 'ffmpeg\bootstrap-wsl.sh')
        Write-Output "STAGE wsl build log $log"
        & wsl.exe -d Ubuntu -- env "BUILD_LOG=$logWsl" bash $bootstrap --toolchain $toolchainWsl --cache $cacheWsl --output $outputWsl
        if ($LASTEXITCODE -ne 0) {
            Write-Output "BUILD_FAILED wsl exit $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    }
}

foreach ($tool in @('ffmpeg.exe', 'ffprobe.exe')) {
    $toolPath = Join-Path $output $tool
    if (-not (Test-Path $toolPath)) {
        throw "The build did not produce $tool."
    }

    Unblock-File $toolPath
    $bytes = [System.IO.File]::ReadAllBytes($toolPath)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($text.Contains('fftw_dft')) {
        throw "$tool contains FFTW symbols. FFTW is GPL and is not a RightClip build."
    }
}

$ffmpeg = Join-Path $output 'ffmpeg.exe'
$ffprobe = Join-Path $output 'ffprobe.exe'
$version = (& $ffmpeg -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg -version failed: $version"
}

$probeVersion = (& $ffprobe -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "ffprobe -version failed: $probeVersion"
}

foreach ($flag in @('--enable-gpl', '--enable-nonfree', '--enable-version3', '--enable-libx264', '--enable-libx265', '--enable-libzvbi', '--enable-shared')) {
    if ($version.Contains($flag)) {
        throw "The built FFmpeg contains prohibited option $flag."
    }
}

foreach ($flag in @('--enable-libopenh264', '--enable-libkvazaar', '--enable-libvpx', '--enable-libaom', '--pkg-config-flags=--static')) {
    if (-not $version.Contains($flag)) {
        throw "The built FFmpeg is missing $flag."
    }
}

$encoders = (& $ffmpeg -hide_banner -encoders 2>&1 | Out-String)
$decoders = (& $ffmpeg -hide_banner -decoders 2>&1 | Out-String)
$filters = (& $ffmpeg -hide_banner -filters 2>&1 | Out-String)
foreach ($name in @('libopenh264', 'libkvazaar', 'libvpx', 'libvpx-vp9', 'libaom-av1', 'mpeg4', 'mpeg2video', 'mjpeg', 'png')) {
    if ($encoders -notmatch "(?m)\s$([regex]::Escape($name))\s") {
        throw "The built FFmpeg is missing encoder $name."
    }
}

foreach ($name in @('h264', 'hevc', 'vp8', 'vp9', 'av1', 'aac', 'opus', 'vorbis', 'mp3')) {
    if ($decoders -notmatch "(?m)\s$([regex]::Escape($name))\s") {
        throw "The built FFmpeg is missing decoder $name."
    }
}

foreach ($name in @('scale', 'hstack', 'select', 'showinfo', 'reverse')) {
    if ($filters -notmatch "(?m)^\s+\S+\s+$([regex]::Escape($name))\s") {
        throw "The built FFmpeg is missing filter $name."
    }
}

Add-Content -Path $log -Value 'BUILD_OK'
Write-Output 'BUILD_OK'
Write-Output $version
