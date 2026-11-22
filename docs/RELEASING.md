# Build and release engineering

## Continuous integration

The Build workflow runs on pushes and pull requests with read-only repository
permissions and no signing secrets. It builds the managed solution, runs unit
and real-media tests, analyzes PowerShell, builds the native extension, packages
a development identity, and runs installer/UI/native smoke tests.

CI artifacts are development test builds, not production releases. Downloading
them does not require installing a certificate; portable smoke tests do not
register Explorer commands or change machine certificate trust.

```powershell
pwsh -NoProfile -File .\eng\Publish-RightClip.ps1 -DevelopmentSigning
pwsh -NoProfile -File .\eng\Test-Installer.ps1
pwsh -NoProfile -File .\eng\Test-ProductionSigning.ps1
```

Development packaging creates signing material only under the ignored
`third_party\signing` directory and a certificate in Current User > Personal.
It never trusts that certificate in Trusted People. Use a disposable Windows
development environment for packaging tests.

`-DevelopmentSigning` explicitly selects the development publisher and skips
Azure executable signing, regardless of inherited Azure signing variables.
Those variables are not changed. Without the switch, incomplete production
signing configuration still fails rather than silently producing a development
package. The signing smoke test covers both modes and their installers.

For a local development installation, select the certificate-consent checkbox
in Setup and approve the Windows UAC request. Only certificate trust runs
elevated; installation, shortcuts, and per-user registration stay under the
original user. Production installations do not require this helper. Automated
tests check UAC cancellation and packaged-helper rejection without importing
certificates; approve a real UAC prompt only during an interactive installation
check on a disposable Windows machine.

## FFmpeg pin

`eng\ffmpeg.json` selects a dated binary release and the exact FFmpeg source
commit with SHA-256 hashes. The downloader fails closed on a mismatch; never
disable hash or license checks to make a build pass.

Upstream dated assets can eventually be removed. If an asset becomes unavailable,
review and update the binary and source pins together. Verify the actual
configuration, matching source commit, and all included license texts. Do not
fall back to a moving `latest` URL or a GPL/nonfree/shared build.

The ZIP contains the corresponding FFmpeg source archive, configuration record,
and LGPL/GPL license texts. Those texts do not change the MIT license of
RightClip's own code. Review [NOTICE.md](../NOTICE.md) before redistributing.

**Binary publication blocker:** Set the protected `release` environment
variable `FFMPEG_REDISTRIBUTION_APPROVED=true` only after the pinned bundle
has been reviewed. The pin includes the FFmpeg source, the five linked
library archives, their notices, and the winpthreads notice. This variable is an explicit maintainer
approval, not an automated license-compliance guarantee. Publishing the MIT
application source without bundled binaries does not depend on that approval.

The pin is RightClip's static build `9.0.2-rightclip`, published at
`ffmpeg-9.0.2-rightclip`. It is gcc 13-win32, LGPLv2.1 or later, and links
zlib, openh264, kvazaar, libvpx, libaom, and static MinGW-w64 winpthreads.
The application package includes those source archives, notices, and the
rebuild recipe. Keep the pin release unmarked as the repository's latest
release. Application downloads stay on the versioned RightClip release,
currently [v1.0-beta](https://github.com/joelst/rightclip/releases/tag/v1.0-beta).
Set `FFMPEG_REDISTRIBUTION_APPROVED=true` only after reviewing that bundle.
The `release` environment has Azure Trusted Signing configured for this repository.

## Production signing setup

Create a GitHub environment named `release` with required reviewers and restrict
deployment to release tags. Configure an Azure federated credential with:

- issuer: `https://token.actions.githubusercontent.com`;
- subject: the release workflow accepts only `repo:OWNER/REPOSITORY:environment:release` or this repository's unique-id subject `repo:joelst@30506169/rightclip@1440461689:environment:release`;
- audience: `api://AzureADTokenExchange`.

Grant the identity only the signing permissions required for the selected
Artifact Signing certificate profile.

Configure these environment secrets:

| Secret | Purpose |
| --- | --- |
| `AZURE_CLIENT_ID` | Federated application's client ID |
| `AZURE_TENANT_ID` | Azure tenant |
| `AZURE_SUBSCRIPTION_ID` | Signing subscription |

Configure these environment variables:

| Variable | Purpose |
| --- | --- |
| `AZURE_TRUSTED_SIGNING_ENDPOINT` | Regional signing endpoint |
| `AZURE_TRUSTED_SIGNING_ACCOUNT_NAME` | Signing account |
| `AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME` | Certificate profile |
| `AZURE_TRUSTED_SIGNING_PUBLISHER` | Exact certificate subject for package identity |
| `FFMPEG_REDISTRIBUTION_APPROVED` | `true` only after the static dependency/source review above |

Never store tokens, PFX files, passwords, or local signing output in git.
Production CI fails if signing configuration is incomplete.

## Cutting a release

1. Ensure the Build workflow passes and review open correctness/security issues.
2. Push a version tag. The release workflow runs `eng/Set-ReleaseVersion.ps1`
   and applies that tag before the build. `v1.0.0-beta` and the short form
   `v1.0-beta` both become product version `1.0.0-beta`. The Windows package
   identity is four numeric parts. A stable tag uses revision 100, a beta uses
   1, a release candidate uses 2, and any other prerelease uses 3. This beta
   is package version `1.0.0.1`. A later stable `v1.0.0` is package version
   `1.0.0.100`, which Windows can install over both `1.0.0.1` and the already
   published `v1.0-beta` package, which remains `1.0.0.0`. Each package part
   is a 16-bit integer, at most 65535.
3. A tag that contains a hyphen is published with the GitHub Actions release
   action as a prerelease and is not marked latest. A stable tag such as
   `v1.0.0` remains a draft until it is published.
4. Approve the protected release environment. The workflow verifies the OIDC
   subject, signs a preflight probe, runs tests, and signs the app, shell DLL,
   bundled `ffmpeg.exe` and `ffprobe.exe`, identity package, and Setup
   executable. The pinned FFmpeg zip stays unsigned so its SHA-256 pin stays valid.
5. Inspect the release and its setup/ZIP artifacts. Test installation,
   upgrade, modern/legacy menus, and uninstall on a disposable Windows machine.
   Check signatures, included matching source/licenses, and the production marker.
6. Publish a stable draft only after verification. Do not relabel development
   artifacts as signed production packages.

Automated smoke tests deliberately do not cover live Explorer registration,
machine-wide development certificate trust, or real Azure signing. Mocked signing
tests exercise the production code path, not certificate-chain trust.

Setup and `Install-RightClip.ps1` remove every installed RightClip package before
they register the menu being installed. A different publisher is a different
Windows package, and leaving that package registered shows a second RightClip
menu. A modern-menu install also unregisters the legacy per-user commands. If
registration then fails, `Install-RightClip.ps1` registers each package it copied
beforehand and restores the legacy keys it cleared. Setup registers the package
it copied beforehand and restores those keys.

## Installer diagnostics and rollback

Setup writes a timestamped log to `%LocalAppData%\RightClip\Logs` and exposes **View log** after completion or failure. Logging is best-effort: an unreadable directory or append failure cannot abort installation. Tests can isolate bundle extraction and logs under `TestResults` with `DOTNET_BUNDLE_EXTRACT_BASE_DIR` and `RIGHTCLIP_SETUP_LOG_DIRECTORY`. The log records phases, PowerShell/Appx output, and exceptions. Appx, legacy COM, shortcut, uninstall-entry, certificate-trust, and file actions are journaled and rolled back in reverse order when a later integration step fails.

Production packages must also pass Windows signature validation before registration; the production marker alone is not accepted as proof of trust. PowerShell registration and uninstall commands use `RemoteSigned`, and development signing selects certificates from the current-user certificate store by thumbprint rather than placing passwords on a command line.

Publishing embeds SHA-256 values for the uninstaller and its directory-validation helper into the portable install script. Installation verifies the payload before sourcing the helper and verifies the installed copies before removing Mark of the Web from those two files. This lets the registered `RemoteSigned` uninstall command run after Explorer extracts a downloaded ZIP, without weakening execution policy or unblocking other payload files. Run the installer from a complete published payload; copying the source install script into a bundle leaves its build-time hash placeholders unresolved and is rejected.

## Public repository checklist

Before the first push, review `git status` and `git ls-files --others
--exclude-standard`. Build output, FFmpeg downloads, test media, and all signing
material must remain ignored. Scan the files and any history being published for
secrets; this repository's ignore rules are not a secret scanner.

Enable private vulnerability reporting, secret scanning/push protection where
available, and a branch ruleset requiring the Build check and reviewed pull
requests. Disable Actions write permissions by default. Keep release approvals
separate from pull-request CI. Review Dependabot updates to pinned actions and
NuGet packages rather than auto-merging them.

Creating the repository, changing visibility, setting branch rules, enabling
GitHub security features, and granting Azure access are owner actions; source
changes alone do not configure these services.
