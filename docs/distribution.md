# Distribution and CI

## Architecture decision — reviewed September 9, 2026

An arm64-only Developer ID app is valid. Universal packaging is a compatibility choice, not a notarization requirement. VolumeBar's published releases target Apple Silicon (M1 or newer), retain a minimum OS of macOS 14.4, and keep an optional universal build for Intel users.

Apple's [September 1, 2026 Rosetta guidance](https://developer.apple.com/news/?id=w5ngl9k2) says macOS 27 is the final general Rosetta release. It still recommends universal binaries for apps transitioning while supporting both Mac architectures. Apple Silicon apps already run natively; changing the CEO does not itself change signing rules.

Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) still require a Developer ID signature, Hardened Runtime, secure timestamp, and valid entitlements. We use `notarytool`, explicitly check `Accepted`, staple the app and installer, and validate both. See [customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## What runs

| Event | Tests + app artifact | Apple signing | Publication |
| --- | --- | --- | --- |
| Pull request (including forks) | Yes | Never | None |
| Branch push | Yes | Only `main` | Prerelease on `main` |
| `vX.Y.Z` tag | Yes | Yes, if reachable from `main` and matching `version.env` | Stable release |
| Manual run | Yes | Only `main` or valid version tags | Same policy as above |

Signing must be enabled with the repository variable `SIGNING_ENABLED=true` after all six secrets are configured in the protected `release` environment. Missing/invalid credentials fail the signing job; they never produce an unsigned public release. With signing disabled, normal CI continues to build downloadable development artifacts.

## Safeguards

- GitHub-hosted `macos-15` Apple Silicon runners with an explicit Xcode 26.3 path; no beta SDK selection or silent toolchain fallback. [Runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
- Actions are pinned to full commit hashes. Dependabot proposes updates.
- Default token permission is read-only. Only the trusted release job can write release assets.
- Checkout does not persist GitHub credentials. No `pull_request_target`, shared signing caches, or third-party signing actions.
- Release environment allows only `main` and version tags. Tagged commits must be ancestors of `main` and match `version.env`.
- Credentials enter only the signing step. Private files use mode 0600 in runner temporary storage, with an isolated keychain. Shell tracing is disabled.
- Cleanup runs both in the signing script's exit trap and in an `always()` workflow step. GitHub destroys the ephemeral runner after the job.
- Tests and build verification must pass before release signing. Bundle metadata, architecture, signature type, team, timestamp, and Hardened Runtime are checked.
- Notarization waits are bounded. A timed-out submission is not blindly resubmitted; inspect its submission ID/log before retrying. Stapling gets bounded retries for ticket propagation.
- Releases begin as drafts. All assets and checksums upload before publication. Completed releases are never overwritten by a rerun; an interrupted draft can be resumed.
- PR builds cancel stale PR runs. Trusted push jobs finish rather than canceling during signing; concurrency queues later pushes for the same ref. GitHub may supersede pending runs during a burst, so every resulting latest commit gets a build, not necessarily every intermediate commit.
- No audio capture or interactive macOS permission prompts on CI. Hardware checks remain opt-in local tests.

## Publish a stable version

1. Update `version.env` and `CHANGELOG.md`; push to `main`.
2. Wait for the signed prerelease to succeed.
3. Create and push the matching tag:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The stable release becomes the README's download destination. Each successful `main` build gets a distinct prerelease tag and source commit, so updates remain traceable.

## If CI fails

Open the failed job. Build failures do not release anything. Signing failures usually mean a missing private key, expired certificate, or wrong team. Notarization failures include a diagnostic JSON artifact when available. If Apple reports `In Progress` after timeout, check the existing submission before running again. A draft left by a failed upload is safe to retry. Fix and push; do not bypass signing checks or publish an ad-hoc build as a normal release.
