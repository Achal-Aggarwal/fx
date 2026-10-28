#!/usr/bin/env bash
# Decide whether a change needs the libfx durable-session model check.
#
# Usage: detect-libfx-need.sh <base-revision> <head-revision>
#
# The check in the SDK (Bun + N-API/WASM) job model-checks tests/tla/sdk/ and
# drives libfx along its state graphs, which takes about 40 minutes. A pull
# request runs it only when it touches code libfx owns: sdk/, the SDK models in
# tests/tla/sdk/, their drivers in tests/tla/drivers/*.mjs, the Node-API and
# WebAssembly core entry points, src/acp/, src/core/hosts/,
# src/core/session_manager/, build.zig, build.zig.zon, or the check itself. A
# change to shared code libfx compiles in, such as the agent loop, is checked
# by the run on main. Set LIBFX_REQUESTED to a reason to force the check.
#
# Writes needed=true|false to $GITHUB_OUTPUT and the reasons to
# $GITHUB_STEP_SUMMARY when those files are set. Exits non-zero when either
# revision cannot be read, so the check fails instead of passing without having
# looked at the change.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"

needed=false
reasons=()

require() {
  needed=true
  reasons+=("$1")
}

for revision in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$revision^{commit}" >/dev/null; then
    printf 'error: cannot read revision %s; the libfx check cannot decide\n' "$revision" >&2
    exit 1
  fi
done

if ! changed_files="$(git diff --name-only --no-renames "$base" "$head")"; then
  printf 'error: git diff %s %s failed; the libfx check cannot decide\n' "$base" "$head" >&2
  exit 1
fi

if [ -n "${LIBFX_REQUESTED:-}" ]; then
  require "$LIBFX_REQUESTED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .github/workflows/ci.yml | scripts/detect-libfx-need.sh)
      require "$path: the libfx check changed" ;;
    build.zig | build.zig.zon)
      require "$path: build configuration changed" ;;
    sdk/*)
      require "$path: libfx SDK changed" ;;
    tests/tla/sdk/*)
      require "$path: libfx model changed" ;;
    tests/tla/drivers/*.mjs)
      # The other drivers' folders hold their own models' code.
      if [[ "${path#tests/tla/drivers/}" != */* ]]; then
        require "$path: libfx driver changed"
      fi ;;
    src/napi_*.zig | src/wasm_core_main.zig)
      require "$path: libfx entry point changed" ;;
    src/acp/* | src/core/hosts/* | src/core/session_manager/*)
      require "$path: code libfx owns changed" ;;
  esac
done <<<"$changed_files"

if [ "$needed" = true ]; then
  printf 'libfx durable-session check needed:\n'
  printf '  %s\n' "${reasons[@]}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### libfx durable-session check runs\n\n'
      printf -- '- %s\n' "${reasons[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
else
  printf 'No libfx-owned change; the libfx durable-session check runs on main.\n'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'No libfx-owned change; the libfx durable-session check runs on main.\n' >>"$GITHUB_STEP_SUMMARY"
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'needed=%s\n' "$needed" >>"$GITHUB_OUTPUT"
fi
