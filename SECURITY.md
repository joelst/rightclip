# Security policy

## Supported versions

Security fixes target the latest published release. Development builds and
older releases are not independently maintained.

## Report a vulnerability

Do not disclose suspected vulnerabilities in public issues or pull requests.
Use **Security > Advisories > Report a vulnerability** on this repository when
private vulnerability reporting is enabled. If the control is unavailable,
contact the maintainer through the contact options on their GitHub profile
to arrange a private report; do not post the exploit publicly.

Include the affected version, Windows version, reproduction steps, impact,
and a minimal non-sensitive example. Never include credentials or private media.
Response times are best effort; there is no guaranteed service-level agreement.

## Security boundaries

RightClip processes media locally using separate FFmpeg/FFprobe processes.
Media files can be hostile inputs: keep RightClip and its bundled tools updated.
RightClip is not a malware scanner or a sandbox for untrusted videos.

The Explorer extension launches the worker and passes paths; it must not decode
media in Explorer. Outputs must not replace source files.

Production signing uses Azure OIDC, not committed signing keys. Development
identity certificates are for testing only; trusting one for all users requires
explicit consent and elevation. Do not distribute development builds as
production-signed releases.

Before opening the repository publicly, enable private vulnerability reporting,
secret scanning and push protection where available. See
[release engineering](docs/RELEASING.md).
