# Contributing to RightClip

RightClip is a standalone Windows video utility. Bug reports, documentation fixes,
tests, and focused pull requests are welcome. Contributions are licensed under
the [MIT License](LICENSE); third-party programs retain their own licenses.

## Before making changes

Read [README.md](README.md) for product behavior and [AGENTS.md](AGENTS.md) for
architecture and contribution boundaries. Discuss new dependencies, UI-stack
changes, shell integration changes, or changes to the three Explorer actions
before implementing them.

Use a feature branch and keep pull requests focused. Explain the problem,
the behavior change, and the tests you ran. Include screenshots for UI changes.
Do not include private videos, local paths, certificates, signing material,
downloaded FFmpeg files, or build output.

## Development

Use Windows x64, PowerShell 7, the .NET SDK selected by `global.json`, and
Visual Studio 2022 C++ x64 tools with a Windows SDK for native builds.

```powershell
dotnet restore RightClip.sln
dotnet build RightClip.sln -c Release --no-restore
dotnet test RightClip.sln -c Release --no-build --no-restore
```

To run the real-media tests, download the verified tools first:

```powershell
pwsh -NoProfile -File .\eng\Get-FFmpeg.ps1
$env:RIGHTCLIP_TEST_FFMPEG_DIR = (Resolve-Path .\third_party\ffmpeg\tools).Path
dotnet test RightClip.sln -c Release
```

These tests generate their own media. Tests without that environment variable
skip real-media integration cases. Keep new regression tests focused on the
behavior being changed.

PowerShell scripts must pass PSScriptAnalyzer without errors or warnings:

```powershell
Invoke-ScriptAnalyzer -Path .\eng -Recurse -Severity Error,Warning
```

The module version used in CI is pinned in the build workflow. See
[release engineering](docs/RELEASING.md) for native, packaging, and smoke tests.
Ordinary builds and tests must not register the extension in live Explorer or
trust a certificate in Local Machine.

## Safety and licensing

Preserve the source video and write new sibling files. Keep media processing
outside Explorer and invoke FFmpeg as a separate process with an argument list,
not a shell. One failed batch item must not stop healthy items.

Do not link FFmpeg libraries into RightClip or package GPL/nonfree builds.
Changes to the FFmpeg pin must preserve matching source and license texts.
See [NOTICE.md](NOTICE.md).

## Reporting issues

Use the issue templates for bugs and feature requests. Include Windows version,
RightClip version, action, expected behavior, and reproducible steps. Redact
private paths and metadata; do not upload sensitive media.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
Be respectful, constructive, and considerate of other contributors.
