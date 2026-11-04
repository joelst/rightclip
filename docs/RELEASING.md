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

**Binary publication blocker:** The upstream static build enables external
libraries, including LGPL dependencies. The FFmpeg archive alone does not
include their corresponding source, build scripts, or all dependency notices.
Complete that inventory and assemble the legally required redistribution
materials before publishing binaries. Set the protected `release` environment
variable `FFMPEG_REDISTRIBUTION_APPROVED=true` only after the materials are
included and reviewed. This is an explicit maintainer approval, not an automated
license-compliance guarantee. Publishing the MIT application source without
bundled binaries does not depend on that approval.

## Production signing setup

Create a GitHub environment named `release` with required reviewers and restrict
deployment to release tags. Configure an Azure federated credential with:

- issuer: `https://token.actions.githubusercontent.com`;
- subject: `repo:OWNER/REPOSITORY:environment:release`, using the actual repository;
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
2. Update the version consistently in `Directory.Build.props`, the package
   manifest, packaging scripts, and versioned documentation.
3. Push a matching tag such as `v0.3.0`, or dispatch Release against that tag.
4. Approve the protected release environment. The workflow verifies the OIDC
   subject, signs a preflight probe, runs tests, and signs the app, shell DLL,
   identity package, and Setup executable.
5. Inspect the draft release and its setup/ZIP artifacts. Test installation,
   upgrade, modern/legacy menus, and uninstall on a disposable Windows machine.
   Check signatures, included matching source/licenses, and the production marker.
6. Publish the draft only after verification. Do not relabel development artifacts
   as signed production packages.

Automated smoke tests deliberately do not cover live Explorer registration,
machine-wide development certificate trust, or real Azure signing. Mocked signing
tests exercise the production code path, not certificate-chain trust.

Uninstall a development modern-menu installation before switching to production
signing: a different publisher represents a different Windows package identity,
not an ordinary same-publisher upgrade.

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
