# Developing RightClip

RightClip is a standalone Windows video utility. This page is for building, testing, and packaging it. How to install and use the app is in [README.md](../README.md).

## Prerequisites

- Windows x64
- The stable .NET 10 SDK (`global.json` selects `10.0.403`; projects target .NET 10)
- Visual Studio 2022 with the C++ x64 toolchain and a Windows 10/11 SDK, for the Explorer extension
- PowerShell 7 or later for the scripts in `eng`

## Repository map

- `src/RightClip.Core`: media model, process execution, validation, and operations
- `src/RightClip.App`: the WPF worker and editor
- `src/RightClip.Setup`: the self-contained WPF installer and the embedded application payload
- `src/RightClip.Shell`: the native C++ `IExplorerCommand` extension, built by the publish script
- `tests/RightClip.Tests`: unit tests and opt-in real-media tests
- `assets`: the SVG, PNG, and multi-size ICO branding; `eng/New-Icon.py` regenerates the rendered assets with Pillow
- `eng`: restore, publish, install, and test scripts
- `packaging`: the sparse identity manifest

The shell extension starts the worker and passes file paths. Decoding, FFmpeg, and the windows run outside Explorer. RightClip runs `ffmpeg` and `ffprobe` as separate processes with an argument list. It does not link FFmpeg libraries.

## Build and test

```powershell
dotnet restore RightClip.sln
dotnet build RightClip.sln -c Release
dotnet test RightClip.sln -c Release
```

Download and verify the pinned LGPL tools before the real-media tests:

```powershell
pwsh -File .\eng\Get-FFmpeg.ps1
$env:RIGHTCLIP_TEST_FFMPEG_DIR = (Resolve-Path .\third_party\ffmpeg\tools).Path
dotnet test RightClip.sln -c Release
```

Without `RIGHTCLIP_TEST_FFMPEG_DIR`, those tests skip and the unit tests still run. The integration tests generate their own small fixtures with native codecs. They check output media, fresh keyframes, source hashes, collisions, and failure isolation.

`RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG=1` lets a development run use a non-compliant FFmpeg found on `PATH`. Release validation still rejects it. A GPL tool directory must never be packaged as RightClip.

PowerShell scripts must pass PSScriptAnalyzer with no errors or warnings:

```powershell
Invoke-ScriptAnalyzer -Path .\eng -Recurse -Severity Error,Warning
```

Ordinary builds and tests must not register the extension in live Explorer or trust a certificate in Local Machine.

## Package

A local development installer:

```powershell
pwsh -File .\eng\Publish-RightClip.ps1 -DevelopmentSigning
```

The script publishes the self-contained app, builds the native extension, verifies the FFmpeg hashes and configuration, builds the sparse identity package, and writes both `dist\RightClip-1.0.0-beta-win-x64-Setup.exe` and `dist\RightClip-1.0.0-beta-win-x64.zip`. The setup executable embeds the application ZIP and its own .NET 10 runtime.

The payload includes the user guide, its screenshots, and the support, security, contributor, and developer pages that guide links to. It also includes the identity package, installer and uninstaller, MIT and third-party notices, .NET runtime notices, the LGPLv2.1, LGPLv3, and GPLv3 texts, the dependency license and patent notices, `licenses\winpthreads-LICENSE`, `FFmpeg-Build.txt`, the rebuild recipe in `ffmpeg-recipe`, `ffmpeg-source.tar.gz`, and the zlib, openh264, kvazaar, libvpx, and libaom source archives. Downloaded tools, source archives, signing material, test media, and release output stay out of git.

`-DevelopmentSigning` uses a self-signed identity and skips executable code signing, even when Azure signing variables are inherited. Production packaging omits that switch. See [release engineering](RELEASING.md).

The pinned tools and their sources are downloaded from the `ffmpeg-9.0.2-rightclip` release while an app build is assembled. That release is a build input. The application people install is the versioned RightClip release, currently [v1.0-beta](https://github.com/joelst/rightclip/releases/tag/v1.0-beta).

### Smoke tests

```powershell
pwsh -File .\eng\Test-Ui.ps1
pwsh -File .\eng\Test-Shell.ps1
pwsh -File .\eng\Test-Installer.ps1
pwsh -File .\eng\Test-ProductionSigning.ps1
```

`Test-Ui.ps1` generates a 24-fps fixture and drives the editor: selection, thumbnails, cut marks, a blocked write, retry, clip durations, preview resizing, writing with the editor hidden, completion choices, the saved skip-notification exit, metadata removal, and a visible thumbnail on each scene-review row. `Test-Shell.ps1` loads the native extension without registering it and checks the root flyout, the four command titles, icons, and one-worker-per-file launches. `Test-Installer.ps1` checks consent defaults, portable install and upgrade, unsafe-directory protection, and the installed app. `Test-ProductionSigning.ps1` mocks Artifact Signing and covers development and production packaging without contacting Azure.

None of these tests change live Explorer registration, machine certificate trust, ransomware protection, or the Windows uninstall list.

For unattended setup checks, `RightClip-Setup.exe --silent --portable --install-dir <folder>` extracts the payload without Explorer registration, shortcuts, certificate trust, or an uninstall entry. A development-signed modern menu in a non-portable silent install requires both `--modern-menu` and `--trust-package-certificate`. A production-signed package needs neither.

### Documentation screenshots

The pictures in [the user guide](../README.md) come from the real editor, using a generated sample with two audio tracks, English soft subtitles, and chapters. Refresh them on an unlocked interactive desktop after publishing:

```powershell
pwsh -File .\eng\Capture-Screenshots.ps1 -OutputDirectory .\TestResults\documentation-screenshots
```

Each run writes a new timestamped folder of window-only PNGs, `overview.png`, and `manifest.json`. Copy the PNGs you want to keep into `docs/images` under the names the guide already uses. The sample video is created in the Public Videos folder as `RightClip sample`, which is the folder shown in the pictures, and that folder is deleted when the run finishes. If `RightClip sample` already exists, the script stops instead of replacing it. The capture isolates settings, performs a real sample export, and cleans up its media and workers. It does not register Explorer or read personal footage. The File Explorer menu picture, `docs/images/explorer-menu.png`, is captured separately because this script does not open that menu.

## Later work

Joining selected pieces into one continuous output, and downscaling, are later work. Keyframe-safe cutting re-encodes the selected range; a later optimization could re-encode only the boundary stretch.

## Release and review notes

Publishing a signed release is described in [RELEASING.md](RELEASING.md). The bundled FFmpeg terms are in [NOTICE.md](../NOTICE.md). The [public-release readiness review](CODE_REVIEW.md) records the reviewed scope and the remaining publication checks.
