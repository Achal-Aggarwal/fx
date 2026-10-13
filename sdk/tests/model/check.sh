#!/bin/sh
# Model-checks DurableSession.tla, PromptIntake.tla, ImageStore.tla and
# AgentRouting.tla with TLC, confirms each witness is violated, and writes
# the state graphs the drive*.mjs scripts walk against the code.
#
# Needs Java 11+ and tla2tools.jar:
#   brew install openjdk
#   mkdir -p ~/.local/share/tla
#   curl -fL -o ~/.local/share/tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
#
# Then drive the code along the graphs:
#   bun drive.mjs send && bun drive.mjs lookup && bun drive.mjs write && bun drive.mjs cutoff
#   bun drive.mjs leased   # the Heartbeat graph, on a World without liveness
#   bun drive.mjs queue    # the QueueHeld graph, on a World whose queue shows it
#   bun drive-intake.mjs   # prompts with image bytes and files
#   bun drive-images.mjs   # images stored once, across crashes and reopens
#   bun drive-agents.mjs send && bun drive-agents.mjs consume   # AgentRouting
set -eu
cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
[ -f "$jar" ] || { echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2; exit 2; }
java=""
for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/java}" /opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then java="$candidate"; break; fi
done
[ -n "$java" ] || { echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2; exit 2; }

work="${TMPDIR:-/tmp}/libfx-model-tlc"
mkdir -p "$work" graphs
status=0
for tool in send lookup write cutoff leased queue; do
    echo "== DurableSession ($tool)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/$tool" -dump dot,actionlabels "graphs/$tool" \
        -config "DurableSession-$tool.cfg" DurableSession.tla > "$work/$tool.log" 2>&1; then
        cat "$work/$tool.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$tool.log"
done
# Each witness must break the invariant named after it: it shows the model
# reaches that state. NoSelfStop breaks TwoActiveNeedsFreeze: without the
# self-stop, two workers are active at once with no freeze at all.
# NoClaimFence breaks EffectsAtMostOnce: a claim that counts on a stale read
# continues the turn from before a call with effects started, and runs it
# again. NoCutoffBound breaks HandoffsBounded: without the bound, a call
# that outlasts every delivery is cut off and run again forever.
# LeasedTwoActive breaks NotTwoActive with Heartbeat: a renewed lease ends a
# woken worker's run at its next renewal, not before, so two can still be
# active at once until it lands.
# LookupRunsAhead breaks EveryCallAfterIntent: a lookup starts before its
# intent is in the chain. LookupNewId breaks IdsAtMostOne: a crash before
# that intent lands has the model ask again, under a new execution id.
# WriteRunsAhead breaks OneExecutionId: a write that ran ahead the same way
# would run under two ids, which is why a write waits for its intent.
for pair in UiInOrder:UiInOrder NoStaleShown:NoStaleShown NotTwoActive:NotTwoActive \
    NoSelfStop:TwoActiveNeedsFreeze NoClaimFence:EffectsAtMostOnce NoCutoffBound:HandoffsBounded \
    LeasedTwoActive:NotTwoActive LookupRunsAhead:EveryCallAfterIntent LookupNewId:IdsAtMostOne \
    WriteRunsAhead:OneExecutionId; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" DurableSession.tla 2>&1 | grep -q -E "Invariant $invariant is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done

# PromptIntake.tla: how a session object takes prompts in. Deadlock checking
# stays on, since a prompt left waiting forever is a failure there; the
# drive graph is the one drive-intake.mjs walks.
for config in PromptIntake PromptIntake-drive; do
    echo "== $config"
    dump=""
    [ "$config" = PromptIntake-drive ] && dump="-dump dot,actionlabels graphs/intake"
    # shellcheck disable=SC2086 # $dump is two words or none
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -cleanup \
        -metadir "$work/$config" $dump -config "$config.cfg" PromptIntake.tla > "$work/$config.log" 2>&1; then
        cat "$work/$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$config.log"
done
# NoGate breaks ImageOrder: a prompt that does not wait for an earlier one
# still preparing its images is stored first. NoCloseCheck breaks
# ClosedStopsPreparing: a prompt still preparing when the agent closes is
# stored anyway. GateHeldOnFailure deadlocks: a failed prompt that never
# lets the prompts behind it go leaves them waiting forever. NoWithdraw
# breaks CancelOnlyWhenSent: a prompt that goes on after an abort before
# its send began has its cancel go out before it does.
for pair in NoGate:"Invariant ImageOrder is violated" NoCloseCheck:"Invariant ClosedStopsPreparing is violated" \
    GateHeldOnFailure:"Deadlock reached" NoWithdraw:"Invariant CancelOnlyWhenSent is violated"; do
    witness="${pair%%:*}" expected="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -workers auto -cleanup -metadir "$work/intake-$witness" \
        -config "PromptIntake-$witness.cfg" PromptIntake.tla 2>&1 | grep -q -F "$expected"; then
        echo "== witness PromptIntake-$witness reached"
    else
        echo "== witness PromptIntake-$witness NOT reached" >&2; status=1
    fi
done

# ImageStore.tla: how a session saves each image once and names it. The
# durable config sends prompts through the log; the engine config straight
# to the core; the drive graph is the one drive-images.mjs walks. Deadlock
# checking stays on: an open that can never finish is a failure.
for config in ImageStore ImageStore-engine ImageStore-drive; do
    echo "== $config"
    dump=""
    [ "$config" = ImageStore-drive ] && dump="-dump dot,actionlabels graphs/images"
    # shellcheck disable=SC2086 # $dump is two words or none
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -cleanup \
        -metadir "$work/$config" $dump -config "$config.cfg" ImageStore.tla > "$work/$config.log" 2>&1; then
        cat "$work/$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$config.log"
done
# SendBeforeStore breaks NoDanglingRef: a prompt sent while its image write
# is in flight leaves a record naming an image the store does not hold.
# NameUnstored breaks NoDanglingRef: a checkpoint names an image an older
# libfx saved inline, which the store never held. DropMissing breaks
# OpenExact: an open that drops an image the store lost runs on a history
# that is not the one saved. RetryLands breaks NoDanglingRef: a retry stores
# nothing, so a log that kept its input would name an image never stored.
# KeepAll breaks WindowHeld: a core that keeps every image outgrows the
# window an open can stage. NeedAll breaks FailsOnlyOnLossInWindow: an open
# that stages every named image fails on one the window had dropped.
for pair in SendBeforeStore:NoDanglingRef NameUnstored:NoDanglingRef DropMissing:OpenExact RetryLands:NoDanglingRef KeepAll:WindowHeld NeedAll:FailsOnlyOnLossInWindow; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -workers auto -cleanup -metadir "$work/images-$witness" \
        -config "ImageStore-$witness.cfg" ImageStore.tla 2>&1 | grep -q -F "Invariant $invariant is violated"; then
        echo "== witness ImageStore-$witness reached"
    else
        echo "== witness ImageStore-$witness NOT reached" >&2; status=1
    fi
done

# AgentRouting.tla: which agent runs a session's turns when an app has
# several. Its graphs are what drive-agents.mjs walks: inputs stored when
# sent (memory, local) and when delivered (Vercel), with process p2 lacking
# one agent. Drains is checked under fairness, a simulation runs a larger
# config, and each witness breaks RunsOnOwner: NoNames is routing without
# names, as before them, and NoOwnerCheck a worker that runs any session it
# is handed.
for config in send consume; do
    echo "== AgentRouting ($config)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/agents-$config" -dump dot,actionlabels "graphs/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        cat "$work/agents-$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/agents-$config.log"
done
for config in drains-send drains-consume; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        echo "== AgentRouting ($config): Drains holds"
    else
        cat "$work/agents-$config.log"; status=1
    fi
done
if "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -simulate num=20000 -depth 50 -deadlock -workers auto -cleanup \
    -metadir "$work/agents-sim" -config AgentRouting-sim.cfg AgentRouting.tla > "$work/agents-sim.log" 2>&1; then
    echo "== AgentRouting (simulation): $(grep -E 'states checked' "$work/agents-sim.log" | tail -1)"
else
    cat "$work/agents-sim.log"; status=1
fi
for witness in NoNames NoOwnerCheck; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" AgentRouting.tla 2>&1 | grep -q -E "Invariant RunsOnOwner is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done
exit "$status"
