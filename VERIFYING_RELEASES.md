# Verifying a Wink release

Every public Wink release publishes a **build provenance attestation** for the
exact `Wink-<version>.dmg` and `Wink-<version>.zip` bytes. The attestation is a
cryptographically signed record binding those bytes to the repository, the
commit, the tag, and the workflow that produced them.

You do not have to trust this page, the download link, or the person who sent
it to you. You can check the bytes yourself.

## Verify a downloaded DMG

Requires [GitHub CLI](https://cli.github.com) **2.68.0 or newer** (`--source-ref`
landed in 2.68.0) and `gh auth login`.

```bash
gh attestation verify Wink-0.7.3.dmg \
  --repo xrf9268-hue/Wink \
  --signer-workflow xrf9268-hue/Wink/.github/workflows/release.yml \
  --source-ref refs/tags/v0.7.3
```

Substitute the version you downloaded in both the filename and the tag.

The same command works for the Sparkle update archive:

```bash
gh attestation verify Wink-0.7.3.zip \
  --repo xrf9268-hue/Wink \
  --signer-workflow xrf9268-hue/Wink/.github/workflows/release.yml \
  --source-ref refs/tags/v0.7.3
```

### Reading the result

| Exit code | Meaning |
| --- | --- |
| `0` | **Verified.** In a script or CI log this prints nothing at all — silence is success. |
| `1` | Verification failed: tampered bytes, no attestation, wrong repository, wrong signer workflow, or wrong source ref. |
| `2` | Cancelled. |
| `4` | You are not signed in. Run `gh auth login`. Nothing was verified. |

**Accept exactly `0`.** Only `0` means verified; every other code means the
artifact is unverified, whether or not it is tampered. A script that rejects
only `1` will treat a missing login (`4`) as success and pass an artifact
nothing ever checked:

```bash
if gh attestation verify "$dmg" --repo … --signer-workflow … --source-ref …; then
  echo "verified"
else
  status=$?
  [ "$status" -eq 4 ] && echo "not signed in — run gh auth login" >&2
  exit 1
fi
```

Branch on `4` only to print a better diagnostic, never to continue.

### Why every flag matters

Dropping a constraint weakens the claim to something that may still pass:

- **`--repo`** — without it, an attestation signed by any repository could satisfy the check.
- **`--signer-workflow`** — without it, any workflow in this repository could have produced the artifact, including one added by a pull request.
- **`--source-ref`** — without it, a build from a branch or a rehearsal run verifies just as happily as the tagged release. This is the flag that separates a real release from a dry run.

## Inspect what was actually attested

```bash
gh attestation verify Wink-0.7.3.dmg --repo xrf9268-hue/Wink --format json \
  | jq '.[].verificationResult.signature.certificate
        | {sourceRepositoryURI, sourceRepositoryRef, sourceRepositoryDigest,
           buildSignerURI, runnerEnvironment}'
```

That prints the repository, the exact tag ref, the **commit SHA** the release was
built from, the workflow file that signed it, and whether it ran on a
GitHub-hosted runner. The predicate type is
`https://slsa.dev/provenance/v1`, wrapped in an in-toto
`https://in-toto.io/Statement/v1` statement.

## Check the digest by hand

```bash
shasum -a 256 Wink-0.7.3.dmg
```

The release run prints the same digests in its job summary under
**Attested artifacts**, computed immediately before attestation and after all
signing and stapling. If your local digest differs, the file you have is not the
file that was attested.

## What this does and does not prove

**It proves** these bytes were produced by this repository's release workflow,
from a specific commit, on a GitHub-hosted runner, and have not changed since.

**It does not prove:**

- **That the source code is safe.** Provenance is about origin, not quality.
- **That macOS will accept the app.** Gatekeeper acceptance comes from Developer ID signing and Apple notarization, which are separate mechanisms tracked in [#440](https://github.com/xrf9268-hue/Wink/issues/440). Builds before that lands are ad-hoc signed and not notarized.
- **That in-app updates are authentic.** Sparkle updates are protected by an EdDSA signature over the appcast enclosure — a different trust root with a different key. `appcast.xml` is a mutable feed and is deliberately **not** attested; an immutable digest would be false the moment the feed is updated.
- **That your Accessibility and Input Monitoring grants will survive.** macOS keys TCC to the code-signing identity; a change of signing mode can require re-granting. That is unrelated to provenance.

These four trust mechanisms — provenance, Developer ID/notarization, Sparkle
signatures, and TCC identity — are independent. None substitutes for another.

## SLSA level

GitHub documents that artifact attestations by themselves provide
**SLSA v1.0 Build Level 2**. Wink claims exactly that and no more.

Build Level 3 additionally requires the build to run in an isolated environment
that the build definition cannot influence, which for GitHub Actions means
generating provenance from a *reusable* workflow. Wink's release job is not one,
so **do not describe Wink's releases as SLSA Build L3**, and do not claim
conformance to the SLSA v1.2 specification, which this repository has not
audited itself against.
