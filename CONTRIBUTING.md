# Contributing to RightClip

RightClip is a standalone Windows video utility. Bug reports, documentation fixes,
tests, and focused pull requests are welcome. Contributions are licensed under
the [MIT License](LICENSE); third-party programs retain their own licenses.

## Before making changes

Read [README.md](README.md) for how the app behaves for someone using it, and
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building and packaging.
[AGENTS.md](AGENTS.md) records architecture and contribution boundaries.
Discuss new dependencies, UI-stack changes, shell integration changes, or
changes to the four Explorer actions before implementing them.

Use a feature branch and keep pull requests focused. Explain the problem,
the behavior change, and the tests you ran. Include screenshots for UI changes.
Do not include private videos, local paths, certificates, signing material,
downloaded FFmpeg files, or build output.

## Development

Build, test, package, and screenshot steps are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Keep new regression tests focused
on the behavior being changed. PowerShell scripts must pass PSScriptAnalyzer
without errors or warnings. Ordinary builds and tests must not register the
extension in live Explorer or trust a certificate in Local Machine.

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
