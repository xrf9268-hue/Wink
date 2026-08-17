# Swift fuzzing feasibility (issue #444)

Date: 2026-08-17

Decision: **Experimental Go for URL-parser fuzzing on macOS arm64 with
Homebrew llvm@17; No-Go for a required Apple-toolchain-only gate.**

The spike found a reproducible path for the smallest pure target in Wink: the
`wink://` URL grammar. The path is intentionally narrow. It compiles Swift with
Apple Swift, requests sanitizer coverage through the hidden frontend flag, and
links the matching Homebrew LLVM 17 libFuzzer runtime by hand. This is good
enough for optional PR evidence and manual maintainer runs, but it is not a
repository-wide required gate and it does not yet cover recipe or persistence
decoding.

## Exact environment

- macOS 15.7.5 (24G624), arm64
- Xcode 26.3 (17C529)
- Apple Swift 6.2.4 (`swiftlang-6.2.4.1.4`, `clang-1700.6.4.2`)
- Apple Clang 17.0.0 (`clang-1700.6.4.2`)
- Swift package tools version 6.0; Wink deployment target macOS 15
- Homebrew `llvm@17` 17.0.6, keg-only
- Homebrew `llvm@17` arm64 Sequoia bottle: 385,222,736 bytes compressed
- Installed `llvm@17` footprint on this host: 1.5 GB, 6,617 files
- Declared formula dependency: `zstd`; installed bottle metadata also records
  `lz4` and `xz` as indirect runtime dependencies

## Apple toolchain probes

The smallest URL harness exports `LLVMFuzzerTestOneInput` and compiles directly
with the production `WinkURLCommand.swift`, avoiding AppKit, Carbon, SkyLight,
persistence, and user-directory surfaces.

Direct Apple Swift still rejects libFuzzer sanitizer mode before compilation:

```text
$ xcrun swiftc -parse-as-library -sanitize=fuzzer,address \
    Sources/Wink/Models/WinkURLCommand.swift \
    Fuzzing/Harnesses/WinkURLFuzzer.swift \
    -o /tmp/wink-url-fuzzer-probe
error: unsupported option '-sanitize=fuzzer' for target 'arm64-apple-macosx15.0'
```

Apple Clang accepts the spelling but cannot link because Xcode does not ship
the Darwin libFuzzer runtime:

```text
$ xcrun clang -fsanitize=fuzzer -x c /dev/null -o /tmp/wink-clang-fuzzer-probe
ld: library '.../usr/lib/clang/17/lib/darwin/libclang_rt.fuzzer_osx.a' not found
clang: error: linker command failed with exit code 1
```

These probes keep the Apple-toolchain-only decision at No-Go.

## Working Homebrew llvm@17 path

`scripts/fuzz-url.sh` implements the reproducible path:

1. Compile the URL parser and harness to one Swift object with Apple Swift:

   ```text
   xcrun swiftc -parse-as-library -whole-module-optimization -emit-object \
     -sanitize=address -Xfrontend -sanitize=fuzzer \
     Sources/Wink/Models/WinkURLCommand.swift \
     Fuzzing/Harnesses/WinkURLFuzzer.swift
   ```

2. Link the object with Apple Swift, Homebrew LLVM 17's Darwin libFuzzer
   archive, and libc++:

   ```text
   xcrun swiftc -sanitize=address WinkURLFuzzer.o \
     /opt/homebrew/opt/llvm@17/lib/clang/17/lib/darwin/libclang_rt.fuzzer_osx.a \
     -Xlinker -lc++ \
     -o .build/fuzz-url/WinkURLFuzzer
   ```

The script fails closed when it is not running on macOS arm64, when Homebrew
`llvm@17` is missing, when the runtime archive is absent, or when the selected
Homebrew clang is not version 17.

## Committed target

- `Fuzzing/Harnesses/WinkURLFuzzer.swift` decodes arbitrary bytes as UTF-8 and
  runs `WinkURLCommand.parseResult` twice.
- The harness asserts deterministic parser output.
- Successful parses are asserted to respect `WinkURLCommand.maximumURLByteCount`.
- The target is pure Foundation code and never touches app state, user files,
  permissions, event taps, activation APIs, or logging.
- The committed corpus contains three seeds:
  `toggle`, `settings`, and `malformed-percent` (98 bytes total).
- The synthetic failure branch is opt-in via
  `-D WINK_FUZZ_SYNTHETIC_FAILURE`; normal fuzz builds never contain it.

## Evidence

- `scripts/fuzz-url.sh replay` passed, replaying all three committed corpus
  files with `-runs=1`.
- `scripts/fuzz-url.sh smoke 60` passed locally with AddressSanitizer and no
  crashes: 911,461 executions, coverage 236, feature count 440, corpus
  104 files / 5,385 bytes, RSS 572 MB.
- `scripts/fuzz-url.sh synthetic-proof` passed. A safe seed plus dictionary
  entry discovered the opt-in synthetic crash, libFuzzer wrote the crash
  artifact, minimization reduced it to `wink://focus?bundle=%ZZ`, and the
  permanent regression
  `WinkURLCommandTests.malformedPercentEscapesHaveABoundedReason` passed.
- `.github/workflows/url-fuzzing.yml` adds an optional macOS 15 workflow for
  pull requests that touch the URL parser, fuzz harness/corpus, script, or the
  workflow itself. It installs `llvm@17`, replays the committed corpus, and runs
  a 60-second smoke.

## Candidate boundary result

| Boundary | Result |
| --- | --- |
| URL grammar | Go for optional/manual macOS arm64 fuzzing through the committed harness, corpus, script, and optional PR workflow. |
| Recipe JSON | Deferred. The codec is mostly pure, but extraction should happen in a separate target so URL parser failures stay isolated. |
| Persistence JSON | Deferred. Needs a pure decoder seam that cannot touch real or temporary user files. |

The boundaries must remain separate. A single stateful fuzz target would blur
ownership and make minimized failures harder to promote into ordinary tests.

## Maintenance policy

- Owner: maintainers changing `WinkURLCommand` or the committed URL fuzzing
  assets.
- Cadence: path-triggered PR workflow plus `workflow_dispatch`; no scheduled
  run yet.
- Merge policy: the fuzzing workflow is supplemental evidence, not a required
  repository gate.
- Runtime scope: this is parser validation only. It is not macOS runtime
  validation for event taps, TCC, activation, packaging, login items, or Focus
  Filter behavior.
- Toolchain risk: `-Xfrontend -sanitize=fuzzer` and manual runtime linking are
  not an official SwiftPM fuzzing contract. If Apple Swift or Homebrew LLVM
  changes this layout, the workflow should fail closed rather than silently
  weakening coverage.

## Revisit criteria

Broaden beyond the current URL parser only after one of these is true:

1. Apple Swift accepts a documented libFuzzer sanitizer mode and the selected
   Xcode ships the matching Darwin runtime.
2. Swift.org publishes a supported SwiftPM fuzzing recipe with a versioned
   runtime available on the repository's macOS runner.
3. The recipe and persistence parsers are extracted into pure seams with tests
   proving they cannot read or mutate real user state.

Every real crash or timeout artifact must still be minimized and promoted to
an ordinary permanent regression test before the corpus is expanded.

## References

- [LLVM libFuzzer documentation](https://llvm.org/docs/LibFuzzer.html)
- [Homebrew llvm@17 formula](https://formulae.brew.sh/formula/llvm@17)
