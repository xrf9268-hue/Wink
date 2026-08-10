# OSV gate fixtures

`known-advisory/Package.resolved` exists to prove the dependency gate in
[`../workflows/osv-scan.yml`](../workflows/osv-scan.yml) can still fail.

A green scan of Wink's real lockfile only shows the gate was quiet. It cannot
distinguish "no known vulnerabilities" from "the Swift extractor stopped
working", "the advisory database was unreachable", or "the scan ran against the
wrong path". This fixture pins `apple/swift-nio` at `2.29.0`, a SwiftPM package
with advisories published in 2023, so every scheduled run re-proves that a real
finding still reaches the gate.

Rules for this directory:

- **Never fix the fixture.** Bumping `swift-nio` to a patched version silently
  turns the proof off; the `negative-proof` job would then pass by reporting
  nothing, which is the exact failure it exists to detect. The assertion runs
  with `OSV_EXPECT_VULNERABILITIES=true`, so a clean scan here fails the job.
- **Never let it be ignored.** `osv-scanner` skips `.gitignore`d files by
  default. If this path is ever ignored, the fixture scan extracts nothing and
  the proof evaporates.
- **It is deliberately a Swift lockfile.** A fixture in another ecosystem would
  prove the scanner runs, but not that the `swift/packageresolved` extractor —
  the one Wink actually depends on — is still enabled.
- **It is isolated from the build.** Nothing in `Package.swift`, the app target,
  or any script reads this file; SwiftPM never resolves it. Downgrading the real
  `Package.resolved` to get this signal is explicitly not allowed.

Expected result, verified with `osv-scanner` 2.5.0:

```console
$ osv-scanner --lockfile=.github/osv-fixtures/known-advisory/Package.resolved \
    --format=json --all-packages --output=/tmp/fixture.json
$ echo $?
1
```

with `github.com/apple/swift-nio@2.29.0` extracted in the `SwiftURL` ecosystem
carrying `GHSA-7fj7-39wj-c64f` among others.
