# macOS signing and permission continuity

## Existing permissions and first access

TokenClock does not bypass macOS privacy controls. The first access to a protected
folder or removable volume may require approval. Migrating from the old ad-hoc
signature to a certificate-backed identity can require approval once more.
Thereafter, keep the installation path, edition identifier and signing identity
consistent. Changing signer, deleting its key, resetting privacy settings or
changing the macOS security policy can still require renewed approval.

## Local developer deployment

Only enrol a local identity after the user approves creating the certificate and
private key. `scripts/macos-signing.py init-local --confirm-create-local-identity`
imports the identity into the login keychain. It does not add root trust, change
the keychain search list, reset TCC, or grant full-disk access. Keychain prompts
must be handled by the user. Never ask for their password in chat.
For unattended local deployments, the user may choose Always Allow for codesign
on this specific private key. Do not broaden other keychain items or store the
login password in a script.

The profile `~/.tokenclock/signing/local-identity.json` contains only a public
certificate fingerprint. The private key remains in the login keychain. Keep
that identity; do not regenerate it for each build. The fixed identifiers are
`com.tokenclock.app.glass` and `com.tokenclock.app.normal`.

Sign staging artifacts with `sign-local --binary PATH --variant glass`. Deploy a
tested local binary using `deploy-local --binary PATH --variant glass`. The tool
backs up the previous binary and LaunchAgent, verifies the pinned certificate,
checks the previous certificate-backed designated requirement, and atomically
replaces the binary without changing the launch path or existing preferences.
Do not copy a fresh ad-hoc build directly over an enrolled runtime. A missing key
must stop the deployment, not silently fall back to ad-hoc signing.

## Public releases and user updates

The v1.6.0 public packages retain the historical precompiled, ad-hoc signed,
non-notarized format used by the published v1.5.12 packages. They do not use the
local developer certificate. Validate this compatibility format explicitly with
`scripts/release.sh ... --legacy-adhoc`; it must not be presented as Apple Developer
ID signing or as preserving privacy grants for un-enrolled recipients.

The default release-validation path requires a fixed edition identifier and an
Apple Developer ID Application signature. A future Developer-ID channel should
complete notarization before publishing, retain the same developer identity, and
clearly disclose any one-time identity migration to existing users.

The installer preserves valid vendor signatures. An explicitly enrolled local
installation re-signs staged downloads with its pinned local key. The key never
leaves that machine. A missing/locked local key, signer change, or signed-to-ad-hoc
downgrade stops the update before replacing the installed clock. Other ad-hoc
installations remain supported with an accurate permission-continuity warning;
certificate enrollment is never automatic.

Validate local continuity with two different binaries signed by the same local
identity: their CDHashes must differ, their designated requirements must match,
and `codesign --verify --strict -R "=OLD_REQUIREMENT" NEW_BINARY` must pass. An ad-hoc
binary with the same identifier must fail that requirement.
