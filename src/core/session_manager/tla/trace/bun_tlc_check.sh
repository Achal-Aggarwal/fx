#!/usr/bin/env bash
# Runs fx's E2E tests under Bun with traces kept, then checks every run with
# TLC: each process's `wiring` trace against Wiring.tla, and each saved log
# against TurnLifecycle, Subagents and, for a fork, ForkLog. Exits 0 only when
# every check is ACCEPTED and the runs held at least MIN_FORKS fork steps.
#
#   bun_tlc_check.sh FX_WORKTREE [TEST_FILE [TEST_NAME_PATTERN]]
#
# FX_WORKTREE is an fx checkout whose zig-out/bin/fx is built. MIN_FORKS
# (default 1) guards against a run that never reached the code under check.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fx="${1:?usage: bun_tlc_check.sh FX_WORKTREE [TEST_FILE [TEST_NAME_PATTERN]]}"
file="${2:-sessions-v2.test.ts}"
pattern="${3:-fork}"
min_forks="${MIN_FORKS:-1}"

[ -x "$fx/zig-out/bin/fx" ] || { echo "build fx first: $fx/zig-out/bin/fx" >&2; exit 2; }
out="$(mktemp -d "${TMPDIR:-/tmp}/fx-bun-tlc.XXXXXX")"
echo "runs kept in $out"

(cd "$fx/tests/e2e" && env -u AI_GATEWAY_API_KEY -u AI_GATEWAY_TEST_API_KEY \
    FX_E2E_TLA_DIR="$out" bun test "$file" -t "$pattern") || {
    echo "bun: the tests failed; TLC not run" >&2
    exit 1
}

traces=()
while IFS= read -r f; do traces+=("$f"); done < <(find "$out" -name '*.wiring.log' | sort)
roots=()
while IFS= read -r d; do roots+=("$d"); done < <(find "$out" -type d -name 'sessions-v2' | sort)
[ "${#traces[@]}" -gt 0 ] || { echo "no wiring traces kept: is FX_E2E_TLA_DIR honored?" >&2; exit 1; }
[ "${#roots[@]}" -gt 0 ] || { echo "no saved logs kept" >&2; exit 1; }

forks="$(cat "${traces[@]}" | grep -c 'action=Fork ' || true)"
echo "traces ${#traces[@]}, saved roots ${#roots[@]}, fork steps $forks"
[ "$forks" -ge "$min_forks" ] || { echo "fewer than $min_forks fork steps reached TLC" >&2; exit 1; }

status=0
echo "== wiring traces against Wiring.tla"
wiring="$(python3 "$here/check_wiring_traces.py" "${traces[@]}")" || status=1
echo "$wiring"
if echo "$wiring" | grep -q -E '^(REJECTED|SKIPPED|TOOL ERROR) +/'; then status=1; fi
# An empty trace is right only for a run on v1, which saves no v2 sessions.
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -d "$(dirname "$path")/sessions-v2" ]; then
        echo "a v2 run left an empty trace: $path" >&2
        status=1
    fi
done < <(echo "$wiring" | sed -n -E 's/^EMPTY +(.*): no wiring lines$/\1/p')
echo "$wiring" | grep -q -E '^ACCEPTED +[1-9]' || { echo "no trace was accepted" >&2; status=1; }
echo "== saved logs against TurnLifecycle, Subagents and ForkLog"
saved="$(python3 "$here/check_saved_logs.py" "${roots[@]}")" || status=1
echo "$saved"
fork_jobs="$(echo "$saved" | awk '$1 == "fork" && $2 == "ACCEPTED" {print $3}')"
[ "${fork_jobs:-0}" -ge "$min_forks" ] || { echo "fewer than $min_forks saved forks checked" >&2; status=1; }
[ "$status" -eq 0 ] && echo "ALL ACCEPTED" || echo "NOT ALL ACCEPTED"
exit "$status"
