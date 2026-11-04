# Public-release readiness review

This review covered the hand-written managed Core, WPF worker, WPF Setup,
native Explorer extension, tests, manifests, project files, PowerShell
installation/build/test scripts, icon generator, and GitHub workflows.
Generated output, downloaded tools, and local signing material were excluded.
The 0.4.0 follow-up review covered the current change set and revisited media safety, UI lifecycle, installer rollback, and release fail-closed behavior.

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

## 0.4.0 review findings

| Priority | Finding | Disposition |
| --- | --- | --- |
| Medium | Concurrent metadata removal shared a non-thread-safe output allocator. | Fixed with synchronized reservation and a 64-way uniqueness regression. |
| Medium | Deleting the temporary output before FFmpeg started created a small ownership race. | The unique temporary file is now retained and owned from creation through the no-overwrite final move. FFmpeg may overwrite only that temporary file. |
| Medium | Extreme source aspect ratios could produce excessively tall preview frames. | Main and scene previews now have bounded target rectangles; timeline thumbnails remain fixed at 160 x 90. |
| Medium | A later keyboard edit could cancel a disposed source, and focus could be restored before the rebuilt mark was ready. | Keyboard edits now commit synchronously and focus the replacement mark, eliminating delayed cancellation sources. UI coverage includes a separate later edit. |
| Medium | Settings could discard or stale the completion-notification preference. | Settings updates preserve the complete immutable record, and progress-checkbox changes update the active view model as well as disk. |
| Medium | Setup did not reject all ancestor/child junctions, and a partial uninstall-entry write could leave an existing entry changed after rollback. | Added link-aware ancestor/descendant validation and snapshot-based uninstall-entry restoration. |
| Medium | A local build with no Azure variables could skip executable signing without an explicit development switch. | Signing now fails closed locally and in CI; tests cover both environments and the explicit development override. |
| Low | Disabled start input could block Trim End or Scene operations, and keyframe forcing applied to every video stream. | Only active time fields are parsed, and keyframe forcing is scoped to the encoded `v:0` stream. |

## PR #10 follow-up review

| Priority | Finding | Disposition |
| --- | --- | --- |
| High | A delayed keyboard move could edit a cut in a newly selected video. | Keyboard moves now commit synchronously on key-down, so no delayed edit survives a video switch. |
| Medium | Cached PFX signing assumed its private key remained in Current User > Personal. | Development packaging re-imports the cached PFX when the store certificate or private key is missing. An isolated remove-and-reimport signing test passed. |
| Medium | The UI smoke test assumed 16:9 even for custom portrait or 4:3 inputs. | Expected geometry now comes from the supplied video's dimensions and rotation. Both generated 16:9 and portrait UI workflows passed. |
| Medium | Toggling a clip rebuilt the timeline without restoring keyboard focus. | The focused clip index is preserved across rebuilds, with a UI assertion on the replacement clip. |
| Medium | Double-second round trips could lose the exact identity of an existing cut. | Existing cuts now carry `TimeSpan`/ticks through selection, movement, removal, and focus. A fractional-timestamp add/move/remove UI regression passed. |
| Medium | Video duration alone excluded late-starting video from the final preview range. | Probe preserves stream start time, and preview duration uses the video endpoint clamped to the container. Parsing and real delayed-video tests passed. |
| High | Mark of the Web on unsigned uninstall scripts could make the registered `RemoteSigned` command fail. | Publishing pins both script hashes in the installer. Installation verifies them before sourcing the helper and again after copying, then unblocks only those two verified files before registration. Tests cover marked payloads, RemoteSigned execution, and rejection of a modified helper without executing it or modifying the target. |
| High | Export during a pending keyboard move could snapshot the previous cut boundary. | The timeline model is updated immediately on every arrow key-down. The UI test exports while the key is held and checks the written clip duration. |
| Medium | Removing the active file could let WPF clear selection before the fallback check. | Removal selects the first remaining video when selection is null or no longer present. The UI test removes an active second video and checks selection, timeline, and export availability. |
| Medium | A second held arrow press could lose movement when the previous delayed commit rebuilt its thumb. | Removing the delay makes each key-down an immediate edit; the regression checks a second press held beyond the old delay and keyboard focus restoration. |
| Medium | Thread-pool progress forwarding could arrive after final Setup status or reorder log phases. | A synchronous progress adapter logs and forwards each phase before returning. A regression verifies thread, ordering, and completion behavior. |
| Medium | Concurrent logging failures could clear the path between the null check and append. | Each report captures one checked local path. Concurrent writes against a locked log remain best-effort without throwing. |

## Follow-up improvements

- Timeline arrow-key movement now accumulates correctly and preserves keyboard focus; the UI regression covers repeated arrows. Every output clip has a distinct non-overlapping thumbnail region with check/cross state, removed-footage shading, and bracket indicators.
- Fast-cut keyframe probing is bounded when possible, batch work is capped at two concurrent jobs, and retained FFmpeg output is capped.
- Production identity packages require Windows signature validation before registration. Development signing uses certificate-store thumbprints and `RemoteSigned` commands.
- Installer actions are journaled and rolled back in reverse order. Setup writes timestamped diagnostics and retries transient directory locks. Logging is best-effort and cannot abort installation.
- Writing and re-encoding replace the editor with a progress window and minimize the base window. Hide hides both windows and exits after completion. Otherwise a result window reports outputs and failures unless the persistent skip-notification option is enabled; closing it restores the base window. The UI suite covers progress replacement, Hide-and-exit, the completion result, and base-window restoration.
- Loading has a visible indicator. The compact frame preview follows the source aspect ratio, defaults to 16:9, and pops out into a resizable window without changing the editor size; UI tests cover pop-out, resize, and inline restoration. Scissors add cuts, and zoom/Fit/Ctrl+wheel plus horizontal panning preserve absolute cut times while making tiny end segments manageable. UI tests cover loading, zoom, and Fit.

## Validation

- Release managed build: zero warnings and errors.
- Managed tests: **83 passed, zero skipped**, including all real-media
  integration tests and the concurrency, bounded-geometry, keyboard, precision, and stream-offset regression cases.
- PSScriptAnalyzer: zero errors and warnings across `eng`.
- GitHub Actions workflows were previously validated with actionlint 1.7.7 and
  were unchanged by the 0.4.0 follow-up; actionlint was unavailable for a rerun.
- Development packaging under CI restrictions and mocked-production packaging
  both passed. Tests verified that unconfigured production signing fails locally
  and in CI, while explicitly permitted unsigned development packaging succeeds.
- Portable installation, upgrades, damaged-install repair, unsafe-directory and
  junction rejection, packaged icon/payload checks, real WPF timeline/review/write,
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
The PR must also pass its GitHub-hosted Build checks before merge.

Before making the repository public, configure branch rules, release reviewers,
private vulnerability reporting, and available secret scanning/push protection
as described in [RELEASING.md](RELEASING.md). No visibility or GitHub/Azure
settings were changed by this review.

This is a point-in-time correctness and release-readiness review, not a guarantee
that the project has no defects or vulnerabilities.
