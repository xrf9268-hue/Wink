#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${WINK_FUZZ_BUILD_DIR:-${ROOT_DIR}/.build/fuzz-url}"
CORPUS_DIR="${ROOT_DIR}/Fuzzing/Corpus/WinkURL"
HARNESS="${ROOT_DIR}/Fuzzing/Harnesses/WinkURLFuzzer.swift"
PARSER="${ROOT_DIR}/Sources/Wink/Models/WinkURLCommand.swift"

usage() {
  cat <<'USAGE'
Usage: scripts/fuzz-url.sh <build|replay|smoke|synthetic-proof> [seconds]

  build             Compile the ASan/libFuzzer URL target.
  replay            Replay every committed corpus file exactly once.
  smoke [seconds]   Fuzz a temporary corpus for 60 seconds by default.
  synthetic-proof   Prove crash capture, minimization, and unit-test promotion.

Requires macOS arm64 and Homebrew llvm@17. Override its prefix with
WINK_FUZZ_LLVM_PREFIX when necessary.
USAGE
}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "error: the proven fuzzing path requires macOS arm64" >&2
  exit 2
fi

if [[ -n "${WINK_FUZZ_LLVM_PREFIX:-}" ]]; then
  LLVM_PREFIX="${WINK_FUZZ_LLVM_PREFIX}"
elif command -v brew >/dev/null 2>&1 && brew --prefix llvm@17 >/dev/null 2>&1; then
  LLVM_PREFIX="$(brew --prefix llvm@17)"
else
  echo "error: Homebrew llvm@17 is required (brew install llvm@17)" >&2
  exit 2
fi

LLVM_CLANG="${LLVM_PREFIX}/bin/clang"
FUZZER_RUNTIME="${LLVM_PREFIX}/lib/clang/17/lib/darwin/libclang_rt.fuzzer_osx.a"

if [[ ! -x "${LLVM_CLANG}" || ! -f "${FUZZER_RUNTIME}" ]]; then
  echo "error: llvm@17 does not contain the expected clang and libFuzzer runtime" >&2
  exit 2
fi
if [[ "$("${LLVM_CLANG}" --version | head -n 1)" != "Homebrew clang version 17."* ]]; then
  echo "error: expected Homebrew clang 17, found: $("${LLVM_CLANG}" --version | head -n 1)" >&2
  exit 2
fi

mkdir -p "${BUILD_DIR}"

run_swiftc() {
  if [[ -n "${SWIFTC:-}" ]]; then
    "${SWIFTC}" "$@"
  else
    xcrun swiftc "$@"
  fi
}

build_target() {
  local output_name="$1"
  shift
  local object_path="${BUILD_DIR}/${output_name}.o"
  local binary_path="${BUILD_DIR}/${output_name}"

  run_swiftc \
    -parse-as-library \
    -whole-module-optimization \
    -emit-object \
    -sanitize=address \
    -Xfrontend -sanitize=fuzzer \
    "$@" \
    "${PARSER}" \
    "${HARNESS}" \
    -o "${object_path}"

  run_swiftc \
    -sanitize=address \
    "${object_path}" \
    "${FUZZER_RUNTIME}" \
    -Xlinker -lc++ \
    -o "${binary_path}"
}

replay_corpus() {
  local binary_path="$1"
  local corpus_files=("${CORPUS_DIR}"/*)
  if [[ ! -e "${corpus_files[0]}" ]]; then
    echo "error: committed URL corpus is empty" >&2
    exit 2
  fi

  "${binary_path}" "${corpus_files[@]}" -runs=1 -max_len=4096 -timeout=5
}

run_smoke() {
  local binary_path="$1"
  local seconds="$2"
  local run_dir
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/wink-url-fuzz.XXXXXX")"
  trap 'rm -rf "${run_dir}"' RETURN

  mkdir -p "${run_dir}/corpus" "${run_dir}/artifacts"
  cp -R "${CORPUS_DIR}/." "${run_dir}/corpus/"
  "${binary_path}" \
    "${run_dir}/corpus" \
    -max_total_time="${seconds}" \
    -max_len=4096 \
    -timeout=5 \
    -artifact_prefix="${run_dir}/artifacts/"
}

run_synthetic_proof() {
  local binary_path="${BUILD_DIR}/WinkURLSyntheticFailureFuzzer"
  local proof_dir
  proof_dir="$(mktemp -d "${BUILD_DIR}/synthetic-proof.XXXXXX")"
  local seed_dir="${proof_dir}/seed-corpus"
  local seed="${seed_dir}/safe-url"
  local dictionary="${proof_dir}/dictionary.txt"
  local captured="${proof_dir}/captured-crash"
  local minimized="${proof_dir}/minimized-crash"
  local expected="${proof_dir}/expected-minimum"
  local capture_log="${proof_dir}/capture.log"
  local minimize_log="${proof_dir}/minimize.log"

  mkdir -p "${seed_dir}"
  printf 'wink://search' > "${seed}"
  printf '"wink://focus?bundle=%%ZZ"\n' > "${dictionary}"
  printf 'wink://focus?bundle=%%ZZ' > "${expected}"

  set +e
  "${binary_path}" \
    "${seed_dir}" \
    -dict="${dictionary}" \
    -runs=100000 \
    -seed=1 \
    -max_len=64 \
    -timeout=5 \
    -exact_artifact_path="${captured}" \
    > "${capture_log}" 2>&1
  local capture_status=$?
  set -e
  if [[ ${capture_status} -eq 0 || ! -s "${captured}" ]]; then
    echo "error: synthetic failure did not produce a crash artifact; see ${capture_log}" >&2
    exit 1
  fi

  set +e
  "${binary_path}" \
    -minimize_crash=1 \
    -max_len=64 \
    -exact_artifact_path="${minimized}" \
    "${captured}" \
    > "${minimize_log}" 2>&1
  local minimize_status=$?
  set -e
  if [[ ${minimize_status} -eq 0 || ! -s "${minimized}" ]]; then
    echo "error: synthetic crash minimization did not reproduce the failure; see ${minimize_log}" >&2
    exit 1
  fi

  if ! cmp -s "${expected}" "${minimized}"; then
    echo "error: synthetic minimization produced an unexpected input; see ${minimize_log}" >&2
    exit 1
  fi

  (
    cd "${ROOT_DIR}"
    swift test --filter WinkURLCommandTests.malformedPercentEscapesHaveABoundedReason
  )
  echo "Synthetic crash capture, minimization, and regression promotion passed (${proof_dir})."
}

MODE="${1:-}"
case "${MODE}" in
  build)
    build_target WinkURLFuzzer
    ;;
  replay)
    build_target WinkURLFuzzer
    replay_corpus "${BUILD_DIR}/WinkURLFuzzer"
    ;;
  smoke)
    SECONDS_TO_RUN="${2:-60}"
    if [[ ! "${SECONDS_TO_RUN}" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: smoke duration must be a positive integer" >&2
      exit 2
    fi
    build_target WinkURLFuzzer
    run_smoke "${BUILD_DIR}/WinkURLFuzzer" "${SECONDS_TO_RUN}"
    ;;
  synthetic-proof)
    build_target WinkURLSyntheticFailureFuzzer -D WINK_FUZZ_SYNTHETIC_FAILURE
    run_synthetic_proof
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
