#!/bin/sh
# Model-check the indexer refresh model with TLC and require each config's
# expected verdict.
#
# refresh.cfg and refresh-simulation.cfg must pass. refresh-mutation.cfg turns
# the reuse guard off and must violate NoStalePublication, which shows that the
# invariant catches unsafe reuse. Each refresh-witness-*.cfg claims that one
# reuse path cannot happen and must be violated, which shows that the path is
# reachable.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
if [ ! -f "$jar" ]; then
    echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2
    exit 2
fi
# Prefer JAVA_HOME, then Homebrew's keg-only openjdk, then java on PATH.
java=""
for candidate in \
    "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
    /opt/homebrew/opt/openjdk/bin/java \
    /usr/local/opt/openjdk/bin/java \
    "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then
        java="$candidate"
        break
    fi
done
if [ -z "$java" ]; then
    echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2
    exit 2
fi

work="${TMPDIR:-/tmp}/indexer-tlc"
mkdir -p "$work"

status=0
# Each line names the spec, the config, and the invariant that must be
# violated, or "-" when the config must pass.
while read -r spec config expect; do
    log="$work/$config.log"
    if "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -deadlock -workers auto -cleanup \
        -metadir "$work/$config" \
        -config "$config.cfg" "$spec.tla" >"$log" 2>&1; then
        code=0
    else
        code=$?
    fi
    if [ "$expect" = "-" ]; then
        if [ "$code" -eq 0 ] && grep -q "No error has been found" "$log"; then
            echo "ok    $config: no error"
        else
            echo "FAIL  $config: expected no error, TLC exited $code (see $log)"
            status=1
        fi
    elif [ "$code" -eq 12 ] && grep -q "Invariant $expect is violated" "$log"; then
        echo "ok    $config: $expect violated, as required"
    else
        echo "FAIL  $config: expected $expect to be violated, TLC exited $code (see $log)"
        status=1
    fi
done <<'EOF'
Refresh refresh -
Refresh refresh-simulation -
Refresh refresh-mutation NoStalePublication
RefreshWitness refresh-witness-NoReuse NoReuse
RefreshWitness refresh-witness-NoReuseAfterEdit NoReuseAfterEdit
RefreshWitness refresh-witness-NoReuseAfterIgnore NoReuseAfterIgnore
RefreshWitness refresh-witness-NoEditAfterReuse NoEditAfterReuse
RefreshWitness refresh-witness-NoIgnoreChangeAfterReuse NoIgnoreChangeAfterReuse
EOF
exit "$status"
