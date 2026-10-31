# AGENTS.md

Instructions for coding agents working in this repository. Read this before editing.

## What this is

RightClip is a Windows File Explorer utility for short video tasks. The product behavior is described in [README.md](README.md). The source license is MIT ([LICENSE](LICENSE)). Bundled FFmpeg programs are covered by [NOTICE.md](NOTICE.md).

The .NET 10 managed solution contains `RightClip.Core` (media/process services), `RightClip.App` (the WPF worker), `RightClip.Setup` (the self-contained WPF installer), and `RightClip.Tests`. The native C++ Explorer extension is in `src/RightClip.Shell`; the sparse identity manifest is in `packaging`; icon sources are in `assets`; release and installation scripts are in `eng`. Setup requires explicit consent before trusting the development identity certificate in Local Computer > Trusted People; that development-only step requires elevation. Production Azure-signed packages do not require manual certificate trust.

## Product rules

- The modern Windows 11 menu has a `RightClip` root flyout with Trim video, Edit tracks, and Video details. All three actions share one worker.
- The sparse identity package and native `IExplorerCommand` implementation provide the modern menu. A legacy per-user registration remains available as a fallback.
- A shell extension only starts the worker and passes file paths. Decoding, FFmpeg, and the dialog run outside Explorer.
- The worker runs `ffmpeg` and `ffprobe` as separate processes, with an argument list and no shell. Do not link `avcodec`, `avformat`, `avutil`, or any other FFmpeg library.
- Ship a static LGPL build of those two programs, configured without `--enable-gpl` and without `--enable-nonfree`. A GPL build, including one with libx264 or libx265, is not a RightClip build.
- Resolve the executables in this order: the directory that contains the app, then an explicit user path, then `PATH`. The installer copy is the default, so a normal install has no extra step.
- Write a new sibling file. Leave the source path unchanged.
- A failure on one file in a batch leaves the other files running.
- Trim start, trim end, and keep-a-range are one operation. Middle removal is a later task.
- Keyframe-safe mode is the default. It re-encodes video at the requested cut and forces a fresh keyframe. Fast stream copy remains optional, snaps to the previous keyframe, and shows the landed time before it runs.
- Batch a duration offset freely. Batch a clock time only when every selected file is at least that long.
- Scene split shows thumbnails and a clip count before it writes. A batch split uses a saved sensitivity and still shows that count.
- UI copy says "audio tracks". Soft subtitles are remuxed. Burning subtitles into the picture is a re-encode and is outside the first version.
- The first formats are MP4, MOV, MKV, and WebM.

## Public copy

README, UI strings, and other user-facing text describe a standalone Windows tool. Do not name a future host project or distribution target.

## License boundaries

- New application code is MIT. Keep the copyright notice in [LICENSE](LICENSE).
- Do not vendor FFmpeg binaries or FFmpeg source into git. The installer build obtains the pinned LGPL binaries, and the release bundle carries the matching source and the LGPLv2.1 text, as [NOTICE.md](NOTICE.md) requires.
- Do not add a library whose license is GPL, or whose only practical grant is LGPL, by linking it into RightClip.

## Commands

```powershell
dotnet restore RightClip.sln
dotnet build RightClip.sln -c Release
dotnet test RightClip.sln -c Release
pwsh -File .\eng\Get-FFmpeg.ps1
pwsh -File .\eng\Publish-RightClip.ps1
pwsh -File .\eng\Test-Ui.ps1
pwsh -File .\eng\Test-Shell.ps1
pwsh -File .\eng\Test-Installer.ps1
pwsh -File .\eng\Test-ProductionSigning.ps1
```

For real-media integration tests, set `RIGHTCLIP_TEST_FFMPEG_DIR` to the verified `third_party\ffmpeg\tools` directory before `dotnet test`. Without it, those tests skip. Build the native extension through `eng\Publish-RightClip.ps1`; do not register it with Explorer during ordinary builds or tests.

## Boundaries

- Ask before adding a dependency, choosing a UI stack, or scaffolding the shell extension.
- Ask before changing the three actions, the RightClip root flyout, or the keyframe-safe default.
- Do not commit secrets, installer certificates, or FFmpeg binaries.
