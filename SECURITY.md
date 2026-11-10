# Security Policy

## Supported versions

SoundOwl is pre-1.0. Security fixes go into the next release, so only the
[latest release](https://github.com/fanckush/SoundOwl/releases/latest) is supported. Please
update before reporting.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/fanckush/SoundOwl/security/advisories/new).
Include:

- what you found and why it is a security issue
- steps to reproduce, or a proof of concept
- the SoundOwl version, macOS version, and Mac model
- how you installed it (DMG, Homebrew, or built from source)

SoundOwl is maintained by one person, so responses are best effort. You will get an
acknowledgement, and a fix will be released as soon as practical. You are welcome to be credited
in the release notes once a fix is out.

## Scope

In scope:

- the SoundOwl app
- how it downloads, verifies and loads the model package in
  `~/Library/Application Support/SoundOwl/Models`
- how it reads your recordings and writes restored copies
- the release artifacts, their signing and notarization, the update feed, and the Homebrew cask

Out of scope:

- the quality of a restoration (that's a bug report, not a security issue)
- bugs in macOS, ONNX Runtime or Sparkle themselves; please report those upstream
- issues that require an attacker who already has full control of your user account

## How SoundOwl works, for reviewers

- Recordings are processed entirely on your Mac. SoundOwl never uploads audio and collects no
  telemetry.
- It goes online for two things only: downloading the model package once, and checking the
  update feed (`appcast.xml` on the latest GitHub release).
- The model package is checked against a SHA-256 pinned in the app before it is unpacked, and
  every file inside is checked again against the package manifest before it is used.
- Updates are installed only if their EdDSA signature matches the key built into the app.
- Release builds use the hardened runtime, are signed with a Developer ID (abaka UG) and are
  notarized by Apple. Check a downloaded copy with
  `spctl -a -vvv --type exec /Applications/SoundOwl.app`.
- Release assets are published with checksums and build provenance attestations on each
  [GitHub release](https://github.com/fanckush/SoundOwl/releases).
