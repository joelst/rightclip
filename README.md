# RightClip

<img src="assets/RightClip.png" alt="RightClip icon" width="72" />

RightClip adds simple video commands to File Explorer. Select one or more videos, pick an action, review the planned outputs, and RightClip writes new files next to the originals. The originals stay unchanged.

The release package includes statically linked LGPL builds of `ffmpeg` and `ffprobe`, their exact matching source, and the applicable license texts. There is no separate download during installation.

**Release availability:** Setup and ZIP names below describe the build output.
Only install a release actually published on this repository's Releases page;
Actions artifacts are development builds, not production-signed releases.
Public binary releases are also gated on completing the static FFmpeg dependency
source/license review described in [NOTICE.md](NOTICE.md).

## Commands

On Windows 11, the **RightClip** root menu opens a flyout with **Trim video**, **Edit tracks**, and **Video details**. All three actions share one worker. A legacy context-menu registration remains available for compatibility.

**Trim video.** Cut a new file from the selection.

- Trim the start or end by a duration offset or clock time.
- Keep a range between a start time and an end time.
- Move the start/end timeline sliders to preview frames and choose cut positions.
- Split on scene changes after reviewing thumbnails and the clip count.

**Edit tracks.** Change audio tracks and soft subtitles by remuxing.

- Keep, drop, or rename audio tracks.
- Keep or drop existing soft subtitles.
- Add SRT, ASS/SSA, WebVTT, or Matroska soft-subtitle inputs, with optional titles and languages.
- Extract selected soft subtitles to new sibling files. Timed text can be converted to SubRip when needed; bitmap subtitles are exported in a Matroska subtitle file.

**Video details.** Change file metadata by remuxing.

- Edit tags, chapters, and the rotation flag.
- Turn on fast start for MP4 and MOV.
- Strip location data.

The same settings can run on every file in the selection. A duration offset applies independently to each file. A clock time is accepted only when every selected file is long enough. A failed probe, plan, or operation is reported for that file and does not stop healthy batch items.

## Cuts and output safety

**Keyframe-safe is the default.** It cuts at the requested frame, re-encodes the video, and forces a fresh keyframe at the beginning of the output. Audio, soft subtitles, metadata, and chapters are preserved. Encoder support depends on the source codec: H.264, HEVC, VP8, VP9, AV1, MPEG-4, MPEG-2, and MJPEG are supported by the pinned LGPL build; unsupported codecs fail clearly rather than silently changing format.

**Fast stream copy is optional.** It preserves the encoded video and snaps a requested start to the previous keyframe. The review shows the landed time before anything is written, and the output duration accounts for that landed start.

The timeline preview is rendered by FFmpeg in the worker, not in Explorer. Sliders use clock positions and stay synchronized with the editable time fields and the final review.

Scene detection always produces a thumbnail and clip-count review first. The sensitivity is saved when a scene operation is prepared and is used for every file in that batch.

The supported source formats are MP4, MOV, MKV, and WebM. Every result is a new, collision-numbered sibling such as `clip.trimmed.mp4`, `clip.scene01.mp4`, `clip.tracks.mkv`, or `clip.details.mp4`. FFmpeg runs in no-overwrite mode. A source cannot be its own output.

Container and codec incompatibilities are reported rather than silently changing format. Soft subtitles are remuxed or converted as soft text only; RightClip does not burn subtitles into the picture.

## Install

Run `RightClip-0.3.0-win-x64-Setup.exe` on Windows x64. The self-contained setup requires no separate .NET installation. Production and legacy installations normally need no administrator rights; development-signed modern-menu registration needs elevation to trust its certificate. GitHub release artifacts are signed with Azure Trusted Signing.

The setup window lets you choose the install location, Explorer commands, and Start Menu shortcut. It defaults to `%LocalAppData%\Programs\RightClip` and creates an Add or Remove Programs entry with the RightClip icon. Upgrades use a staging directory and preserve the previous installation until the new payload is ready.

The modern Windows 11 submenu uses a signed sparse identity package. A development-signed package requires explicit selection of **Trust the development certificate for all users in Local Computer > Trusted People** and administrator rights; Setup never installs that certificate silently. A production package signed through Azure hides this option and requires no manual certificate trust or elevation. You can also choose legacy menu registration. Uninstall removes the identity package and any development certificate it installed; removing a machine-trusted development certificate requires an elevated uninstaller.

Local signing material stays in the ignored `third_party/signing` directory and is never committed. Production releases use Azure OIDC signing and a protected GitHub environment. See [release engineering](docs/RELEASING.md) for configuration and verification.

No Windows restart is required for a first installation. During an upgrade, a running Explorer can keep the previous shell DLL loaded; if the commands do not update, restart only **Windows Explorer**, not your computer. You can uninstall **RightClip** from Windows Settings > Apps > Installed apps.

For a portable installation or scripted deployment, extract `RightClip-0.3.0-win-x64.zip`. Run `pwsh -File .\Install-RightClip.ps1` for legacy registration, or add `-ModernMenu -TrustPackageCertificate` in an elevated PowerShell for a development-signed modern submenu. RightClip can also run directly from that folder without registration. The script-based uninstaller is `Uninstall-RightClip.ps1`.

For unattended Setup testing or portable extraction, `RightClip-Setup.exe --silent --portable --install-dir <folder>` installs the payload without Explorer registration, shortcuts, certificate trust, or an uninstall registry entry. Non-portable silent installation of a development-signed modern menu requires both `--modern-menu` and `--trust-package-certificate`; production-signed packages need neither.

## Use

Select one or more supported videos in Explorer and open **RightClip**, then choose **Trim video**, **Edit tracks**, or **Video details**. The worker reads media information outside Explorer. Adjust the operation, choose **Review and run**, inspect the landed times/thumbnails and output paths, then choose **Write new files**.

Time fields accept seconds (`12.5`), minutes and seconds (`02:15`), or hours, minutes, and seconds (`01:02:03.500`). The file list shows progress and per-file errors. **Open last output folder** opens the most recent successful result.

RightClip looks for `ffmpeg.exe` and `ffprobe.exe` in this order:

1. the application directory;
2. the optional directory in **Settings**;
3. `PATH`.

A normal installation uses the first location. Packaged builds reject GPL, nonfree, shared-library, libx264, and libx265 FFmpeg configurations.

## Build and test

Prerequisites:

- Windows x64 with the stable .NET 10 SDK (`global.json` selects `10.0.403`; projects target .NET 10);
- Visual Studio 2022 with the C++ x64 toolchain and Windows 10/11 SDK;
- PowerShell 7 or later for release and test scripts.

Build the managed solution and run unit tests:

```powershell
dotnet restore RightClip.sln
dotnet build RightClip.sln -c Release
dotnet test RightClip.sln -c Release
```

The solution contains:

- `src/RightClip.Core`: media model, process execution, validation, and operation services;
- `src/RightClip.App`: the WPF worker and review UI;
- `src/RightClip.Setup`: the self-contained WPF installer with the embedded application payload;
- `tests/RightClip.Tests`: unit and opt-in real-media integration tests;
- `src/RightClip.Shell`: the separate native C++ `IExplorerCommand` project, built by the release script;
- `assets`: the original SVG, PNG, and multi-size ICO branding; `eng/New-Icon.py` regenerates the rendered assets with Pillow.

Download and verify the pinned LGPL tools, then include real-media integration tests:

```powershell
pwsh -File .\eng\Get-FFmpeg.ps1
$env:RIGHTCLIP_TEST_FFMPEG_DIR = (Resolve-Path .\third_party\ffmpeg\tools).Path
dotnet test RightClip.sln -c Release
```

Without `RIGHTCLIP_TEST_FFMPEG_DIR`, the seven real-media tests report as skipped and the unit tests still run. The integration tests generate their own small fixtures with native codecs and check output media, fresh keyframes, source hashes, collisions, and failure isolation.

For development only, `RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG=1` permits a non-compliant FFmpeg found on `PATH`. This does not relax release validation, and a GPL tool directory must never be packaged as RightClip.

## Package

Run:

```powershell
pwsh -File .\eng\Publish-RightClip.ps1
```

The script publishes the self-contained app, builds the native extension, verifies the hashes and actual FFmpeg configuration, builds and cryptographically verifies the sparse identity package, and creates both `dist\RightClip-0.3.0-win-x64-Setup.exe` and `dist\RightClip-0.3.0-win-x64.zip`. The setup executable embeds the complete application ZIP and includes its own .NET 10 runtime. The payload includes the signed identity package and public certificate, installer/uninstaller, MIT and third-party notices, .NET runtime notices, LGPLv2.1, the applicable LGPLv3/GPLv3 texts, build configuration, and `ffmpeg-source.tar.gz` for the exact pinned commit. Downloaded tools, source archives, signing material, test media, and release output are ignored by git.

After publishing, these additional smoke tests exercise the actual deliverables:

```powershell
pwsh -File .\eng\Test-Ui.ps1
pwsh -File .\eng\Test-Shell.ps1
pwsh -File .\eng\Test-Installer.ps1
pwsh -File .\eng\Test-ProductionSigning.ps1
```

`Test-Ui.ps1` generates a fixture, moves the actual timeline slider, checks the rendered frame and landed time, completes the review, and verifies the source hash. `Test-Shell.ps1` loads the native COM extension without registering it and verifies the root flyout, all submenu titles, icons, and correctly quoted multi-select launches. `Test-Installer.ps1` opens the setup UI, runs portable installation and upgrade passes, checks unsafe-directory protection and the embedded icon/payload, then tests the installed app. `Test-ProductionSigning.ps1` mocks the Artifact Signing module to verify the production publisher, signing, payload marker, and installer path without contacting Azure. None of these tests changes live Explorer registration, certificate trust, or the Windows uninstall list.

## Later work

Middle removal and downscaling remain later work. Keyframe-safe cutting currently re-encodes the selected video range; a future optimization could re-encode only the boundary stretch. This version targets Windows x64, and ordinary tests do not register the Explorer extension or identity package.

## License

RightClip source code is [MIT](LICENSE), copyright (c) 2026 Joel Stidley.

The bundled `ffmpeg` and `ffprobe` programs are separate programs under the LGPLv2.1 or later. The pinned build enables version 3 of the LGPL; its applicable license texts and exact source ship with the release. See [NOTICE.md](NOTICE.md).

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull requests,
[SUPPORT.md](SUPPORT.md) for bug reports, and [SECURITY.md](SECURITY.md) for private
vulnerability reporting.

The [public-release readiness review](docs/CODE_REVIEW.md) records the reviewed
scope, fixes, validation, and remaining binary-publication requirements.
