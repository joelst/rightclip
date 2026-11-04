# RightClip

<img src="assets/RightClip.png" alt="RightClip icon" width="72" />

RightClip adds simple video commands to File Explorer. Right-click a video, choose **Trim video**, mark the pieces you want, and export new clips next to the original. The original stays unchanged. Audio-track and metadata tools are available from the same menu.

The release package includes statically linked LGPL builds of `ffmpeg` and `ffprobe`, their exact matching source, and the applicable license texts. There is no separate download during installation.

**Release availability:** Setup and ZIP names below describe the build output.
Only install a release actually published on this repository's Releases page;
Actions artifacts are development builds, not production-signed releases.
Public binary releases are also gated on completing the static FFmpeg dependency
source/license review described in [NOTICE.md](NOTICE.md).

## Commands

On Windows 11, the **RightClip** root menu opens a flyout with **Trim video**, **Edit tracks**, **Video details**, and **Remove Metadata**. All four actions share one worker. A legacy context-menu registration remains available for compatibility.

**Trim video.** Open directly on the selected video and export the pieces you want.

- See the complete video as a thumbnail timeline and scrub to preview a frame.
- Add cuts with the **Add cut** icon, a right-click on the timeline, or a double-click. Drag marks to move them; remove marks with the **Remove cut** icon, Delete, or the mark's context menu. The reset icon restores the full video.
- Click pieces to include or exclude them, then choose **Export** once. Each selected piece becomes a separate sibling clip.
- Use **Advanced** for encoding options, batch duration/clock-time trimming, keeping a range, or scene splitting with thumbnail and clip-count review.

**Edit tracks.** Change audio tracks and soft subtitles by remuxing.

- Keep, drop, or rename audio tracks.
- Keep or drop existing soft subtitles.
- Add SRT, ASS/SSA, WebVTT, or Matroska soft-subtitle inputs, with optional titles and languages.
- Extract selected soft subtitles to new sibling files. Timed text can be converted to SubRip when needed; bitmap subtitles are exported in a Matroska subtitle file.

**Video details.** Change file metadata by remuxing.

- Edit tags, chapters, and the rotation flag.
- Turn on fast start for MP4 and MOV.
- Strip location data.

**Remove Metadata.** Runs immediately without a review dialog or action buttons.
It remuxes a new sibling such as `video-without-metadata.mp4`, clearing file and
track tags, chapters, and rotation. The small window shows progress, then
**Completed file is in:** and the output path. Video, audio tracks, and soft
subtitles are copied without re-encoding. Container fields required for playback
and metadata embedded inside encoded media may remain; this is not a complete
privacy-sanitization tool.
Removing the rotation flag can change the displayed orientation of a video.

Manual cut marks belong to the active video; switching videos preserves their separate timelines. Advanced batch operations, audio-track settings, and metadata settings can run on every listed file. A duration offset applies independently to each file. A clock time is accepted only when every listed file is long enough. A failed probe, plan, or operation is reported for that file and does not stop healthy batch items.

## Cuts and output safety

**Keyframe-safe is the default.** It cuts at the requested frame, re-encodes the video, and forces a fresh keyframe at the beginning of the output. Audio, soft subtitles, metadata, and chapters are preserved. Encoder support depends on the source codec: H.264, HEVC, VP8, VP9, AV1, MPEG-4, MPEG-2, and MJPEG are supported by the pinned LGPL build; unsupported codecs fail clearly rather than silently changing format.

**Fast stream copy is optional.** It preserves the encoded video and snaps a requested start to the previous keyframe. The review shows the landed time before anything is written, and the output duration accounts for that landed start.

The timeline and frame preview are rendered by FFmpeg in the worker, not in Explorer. Opening a video shows a loading message and indeterminate progress bar. The compact inline preview follows the video's aspect ratio, defaulting to 16:9 until dimensions are known. Use the pop-out icon for a separately resizable preview; the inline frame collapses while popped out and returns when the preview window closes. Short editor windows also collapse the inline frame to protect the timeline and export controls, while leaving pop-out available. The scissors button adds a cut, and changing cuts immediately recalculates clip widths and marker positions. Use the **−**, **+**, and **Fit** buttons, or Ctrl+mouse wheel, to zoom and pan without changing absolute cut times or export behavior. Every output clip has its own thumbnail and a check/cross indicator. Excluded footage is dimmed with a cross, and `[`/`]` indicators show where kept footage starts and ends. Small, approximate keyframe thumbnails load together in one process and are cached when switching videos; the main frame preview remains accurate. Arrow keys move a cut by 0.04 seconds and preserve keyboard focus. Moving a mark preserves the selection on each side. Adding a mark inherits that piece's selection. Removing a boundary between an included and excluded piece leaves the merged piece excluded, so previously excluded footage is not exported accidentally. **Reset cuts** restores one selected full-length piece.

Batch operations run at most two independent jobs concurrently with ordered results. Fast-cut keyframe probing uses a bounded time window when possible, with a full scan as a fallback. FFmpeg diagnostic output is drained but retained output is capped to avoid unbounded memory growth.

Scene detection always produces a thumbnail and clip-count review first. The sensitivity is saved when a scene operation is prepared and is used for every file in that batch.

The supported source formats are MP4, MOV, MKV, and WebM. Every result is a new, collision-numbered sibling such as `video.clip01.mp4`, `clip.trimmed.mp4`, `clip.scene01.mp4`, `clip.tracks.mkv`, `clip.details.mp4`, or `clip-without-metadata.mp4`. Outputs are committed without overwriting existing files. A source cannot be its own output. If a multi-clip export fails or is cancelled, its completed clips are removed and cleanup errors are reported explicitly.

If saving is denied, RightClip keeps the original and your cut selections and
shows retry guidance. Check the folder's write permissions. If Windows
**Controlled folder access** blocked the write, allow `RightClip.exe` and the
bundled `ffmpeg.exe` in Windows Security > Virus & threat protection > Ransomware
protection > Allow an app through Controlled folder access, then retry. Do not
disable ransomware protection.

Container and codec incompatibilities are reported rather than silently changing format. Soft subtitles are remuxed or converted as soft text only; RightClip does not burn subtitles into the picture.

## Install

Run `RightClip-0.4.0-win-x64-Setup.exe` on Windows x64. The self-contained setup requires no separate .NET installation. Production and legacy installations normally need no administrator rights; development-signed modern-menu registration needs elevation to trust its certificate. GitHub release artifacts are signed with Azure Trusted Signing.

The setup window lets you choose the install location, Explorer commands, and Start Menu shortcut. It defaults to `%LocalAppData%\Programs\RightClip` and creates an Add or Remove Programs entry with the RightClip icon. Upgrades use a staging directory and preserve the previous installation until the new payload is ready.

Setup writes a timestamped diagnostic log to `%LocalAppData%\RightClip\Logs` and exposes **View log** after completion or failure. Logging is best-effort and cannot block installation. Integration actions are journaled and rolled back in reverse order if a later step fails. Production packages must also pass Windows signature validation before registration; the production marker alone is not accepted as proof of trust.

The modern Windows 11 submenu uses a signed sparse identity package. A development-signed package requires explicit selection of **Trust the development certificate for all users in Local Computer > Trusted People**. Setup then requests Windows administrator approval for a certificate-only helper; the rest of the installation stays in your original user account. Cancelling approval leaves trust unchanged and lets you retry or choose the legacy menu. Setup never installs that certificate silently. A production package signed through Azure hides this option and requires no manual certificate trust or elevation. Uninstall removes the identity package and any development certificate it installed; removing a machine-trusted development certificate requires an elevated uninstaller.

Local signing material stays in the ignored `third_party/signing` directory and is never committed. Production releases use Azure OIDC signing and a protected GitHub environment. See [release engineering](docs/RELEASING.md) for configuration and verification.

No Windows restart is required for a first installation. During an upgrade, a running Explorer can keep the previous shell DLL loaded; if the commands do not update, restart only **Windows Explorer**, not your computer. You can uninstall **RightClip** from Windows Settings > Apps > Installed apps.

For a portable installation or scripted deployment, extract `RightClip-0.4.0-win-x64.zip`. Run `pwsh -File .\Install-RightClip.ps1` for legacy registration, or add `-ModernMenu -TrustPackageCertificate` in an elevated PowerShell for a development-signed modern submenu. RightClip can also run directly from that folder without registration. The script-based uninstaller is `Uninstall-RightClip.ps1`.

For unattended Setup testing or portable extraction, `RightClip-Setup.exe --silent --portable --install-dir <folder>` installs the payload without Explorer registration, shortcuts, certificate trust, or an uninstall registry entry. Non-portable silent installation of a development-signed modern menu requires both `--modern-menu` and `--trust-package-certificate`; production-signed packages need neither.

## Use

Right-click a supported video in Explorer and choose **RightClip > Trim video**. That video is already selected. Scrub the timeline, add or move cut marks, toggle the pieces to keep, and choose **Export**. Accurate cutting is the default and needs no extra confirmation dialog; fast copy still reviews landed keyframes before writing. The window shows the selected clip count and new filenames.

When several videos are opened, choose the active video at the top. Manual cuts apply only to that video. For batch trimming or scene splitting, open **Advanced** and choose **Review batch / scene operation**. **Edit tracks** and **Video details** retain their **Review and run > Write new files** flow.

Writing and re-encoding replace the editor with a small progress window showing the current file and percentage; the editor is minimized meanwhile. **Hide** hides both windows and exits RightClip when the work finishes. **Skip notification when complete** saves your preference; otherwise a result window reports completed outputs and failures, with an option to open the output folder. Closing the result restores the editor; if notifications are skipped, it returns as soon as the work finishes.

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

Without `RIGHTCLIP_TEST_FFMPEG_DIR`, the real-media tests report as skipped and the unit tests still run. The integration tests generate their own small fixtures with native codecs and check output media, fresh keyframes, source hashes, collisions, and failure isolation.

For development only, `RIGHTCLIP_ALLOW_DEVELOPMENT_FFMPEG=1` permits a non-compliant FFmpeg found on `PATH`. This does not relax release validation, and a GPL tool directory must never be packaged as RightClip.

## Package

For a local development installer, run:

```powershell
pwsh -File .\eng\Publish-RightClip.ps1 -DevelopmentSigning
```

The script publishes the self-contained app, builds the native extension, verifies the hashes and actual FFmpeg configuration, builds and cryptographically verifies the sparse identity package, and creates both `dist\RightClip-0.4.0-win-x64-Setup.exe` and `dist\RightClip-0.4.0-win-x64.zip`. The setup executable embeds the complete application ZIP and includes its own .NET 10 runtime. The payload includes the signed identity package and public certificate, installer/uninstaller, MIT and third-party notices, .NET runtime notices, LGPLv2.1, the applicable LGPLv3/GPLv3 texts, build configuration, and `ffmpeg-source.tar.gz` for the exact pinned commit. Downloaded tools, source archives, signing material, test media, and release output are ignored by git.

`-DevelopmentSigning` uses a self-signed identity and skips executable code signing, even when Azure signing variables are inherited. Production packaging omits that switch and requires the Azure configuration described in [release engineering](docs/RELEASING.md). Development builds are not production releases.

After publishing, these additional smoke tests exercise the actual deliverables:

```powershell
pwsh -File .\eng\Test-Ui.ps1
pwsh -File .\eng\Test-Shell.ps1
pwsh -File .\eng\Test-Installer.ps1
pwsh -File .\eng\Test-ProductionSigning.ps1
```

`Test-Ui.ps1` generates a 24-fps fixture, checks automatic video selection and full-length thumbnails, tests cut icons and the accessible timeline context menu, adds/moves/removes marks, restores permissions after a simulated blocked write, retries with the same clip selection, and verifies clip durations/source hashes. It also checks automatic, button-free metadata removal. `Test-Shell.ps1` loads the native COM extension without registering it and verifies the root flyout, all four submenu titles, icons, and correctly quoted multi-select launches. `Test-Installer.ps1` checks consent defaults and safe certificate-helper rejection, runs portable installation/upgrade passes, checks unsafe-directory protection and the embedded icon/payload, then tests the installed app. `Test-ProductionSigning.ps1` mocks the Artifact Signing module to verify both development and production packaging without contacting Azure. None of these tests changes live Explorer registration, machine certificate trust, ransomware protection, or the Windows uninstall list.

## Later work

Joining selected pieces into one continuous output and downscaling remain later work. Keyframe-safe cutting currently re-encodes the selected video range; a future optimization could re-encode only the boundary stretch. This version targets Windows x64, and ordinary tests do not register the Explorer extension or identity package.

## License

RightClip source code is [MIT](LICENSE), copyright (c) 2026 Joel Stidley.

The bundled `ffmpeg` and `ffprobe` programs are separate programs under the LGPLv2.1 or later. The pinned build enables version 3 of the LGPL; its applicable license texts and exact source ship with the release. See [NOTICE.md](NOTICE.md).

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull requests,
[SUPPORT.md](SUPPORT.md) for bug reports, and [SECURITY.md](SECURITY.md) for private
vulnerability reporting.

The [public-release readiness review](docs/CODE_REVIEW.md) records the reviewed
scope, fixes, validation, and remaining binary-publication requirements.
