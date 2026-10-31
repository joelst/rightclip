# Public-release readiness review

This review covered the hand-written managed Core, WPF worker, WPF Setup,
native Explorer extension, tests, manifests, project files, PowerShell
installation/build/test scripts, icon generator, and GitHub workflows.
Generated output, downloaded tools, and local signing material were excluded.
The repository had no commits, so there was no committed history to audit.

## Findings and disposition

| Priority | Finding | Disposition |
| --- | --- | --- |
| High | Failure cleanup could delete a file created at the reviewed output path by another operation. | Fixed in `FFmpegExecutor.RunOutputAsync`: write a unique temporary sibling and commit with a no-overwrite move. Cleanup only touches files owned by the operation. |
| High | Portable uninstall accepted an arbitrary directory for recursive deletion. | Fixed with shared directory validation, same-installation enforcement, link/root rejection, and registered-location ownership checks. |
| High | Development certificate ownership was not recorded; uninstall suppressed machine-trust removal errors. | Fixed with an ownership record preserved during upgrades, elevated removal preflight, explicit failures, and failed-upgrade trust cleanup. Pre-existing certificates are not claimed or removed. |
| Medium | A failed later scene clip or subtitle extraction left earlier outputs unreported. | Fixed by rolling back completed outputs for that source and surfacing cleanup failures. Healthy batch items remain independent. |
| Medium | Default trim review incorrectly described re-encoding as fast stream copy. | Fixed by deriving the description from the plan's encoding; the UI smoke test checks the default review text. |
| Medium | Modern-menu upgrade removed the old package before attempting the replacement. | Fixed by letting Windows deploy/update the package without a preliminary unregister, with terminating registration errors and concurrent stdout/stderr reads. |
| Medium | A moving FFmpeg binary URL conflicted with a fixed hash and could break clean builds. | Fixed with a dated release asset, updated verified hash, and unchanged matching FFmpeg source commit. |
| Medium | PRs had no build workflow; release permissions and repository-specific OIDC assumptions were too broad. | Added unprivileged CI, full action commit pins, SDK pin selection, explicit native exit checks, protected-environment release permissions, dynamic repository OIDC subject, and version-tag checks. |
| Medium | Development PFX passwords were stored as plaintext; PowerShell analysis reported errors/warnings. | Replaced password storage with current-user Windows DPAPI, migrated the old local format, and resolved analyzer findings. |
| Release blocker | The static upstream FFmpeg build includes external libraries whose corresponding source/build materials and notices are not all supplied by the FFmpeg source archive. | Documented in `NOTICE.md`; public binary releases fail closed until the protected environment explicitly approves a completed redistribution review. This does not block publishing the MIT application source without binaries. |

## Validation

- Release managed build: zero warnings and errors.
- Managed tests: **45 passed, zero skipped**, including all seven real-media
  integration tests and six new failure/cancellation/collision regression cases.
- PSScriptAnalyzer: zero errors and warnings across `eng`.
- GitHub Actions: both workflows validated with actionlint 1.7.7.
- Development packaging under CI restrictions and mocked-production packaging
  both passed. Tests verified that unconfigured production signing fails and
  explicitly permitted unsigned development packaging succeeds.
- Portable installation, upgrades, damaged-install repair, unsafe-directory
  rejection, packaged icon/payload checks, real WPF timeline/review/write,
  source hash preservation, and native multi-select launches passed for both
  package paths.
- NuGet advisory audit reported no vulnerable direct or transitive packages
  against the configured NuGet sources.
- Publishable text files were checked for common private-key, GitHub-token,
  AWS-access-key, and connection-string key patterns without printing values.
  No matches were found. This is not a comprehensive secret-scanner guarantee.

## Remaining publication requirements

Publishing source and publishing signed binaries are separate milestones.
Before binary distribution, complete the external FFmpeg dependency/source
inventory and license materials, then validate actual Azure signatures and live
modern/legacy installation and uninstall on a disposable Windows machine.

Automated tests did not register live Explorer commands, change machine-wide
certificate trust, or contact Azure. Certificate-trust cleanup and real Windows
package deployment therefore received code review but not elevated/live
integration testing. Mocked signatures are not production trust-chain validation.
GitHub-hosted execution also remains to be observed after the first push.

Before making the repository public, configure branch rules, release reviewers,
private vulnerability reporting, and available secret scanning/push protection
as described in [RELEASING.md](RELEASING.md). No repository was created or
published and no visibility or GitHub/Azure settings were changed by this work.

This is a point-in-time correctness and release-readiness review, not a guarantee
that the project has no defects or vulnerabilities.
