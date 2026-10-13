# TLA+ models

TLA+ specifications for fx, checked with TLC, together with the scripts and Bun drivers that check them. CI runs the SDK model. Run the others when you change the behavior they describe.

| Folder | What it models | Checker |
|---|---|---|
| `session_manager/` | The session log, turn lifecycle, writer lock, snapshots, fork, subagents, catalog, host wiring, the side-file move, and v1 conversion. `system-design.md` is the design record the specs check and defines the `D1` to `D62` decision numbers that code comments cite. | `session_manager/check.sh` |
| `indexer/` | Refreshing a scanned root, and when a previous listing may be reused. | `indexer/check.sh` |
| `sdk/` | libfx durable sessions (`DurableSession.tla`), agent names and routing (`AgentRouting.tla`), and steering (`DurableSteer.tla`). `check.sh` also writes the TLC state graphs the drivers walk. | `sdk/check.sh`, then the drivers |
| `drivers/` | The Bun drivers. `drive.mjs`, `drive-agents.mjs`, and `drive-steer.mjs` walk the real SDK code along the `sdk/` state graphs and check every step against the model. | `bun drivers/drive.mjs`, `bun drivers/drive-agents.mjs` |

## Requirements

Java 11 or later and `tla2tools.jar`:

```sh
brew install openjdk
mkdir -p ~/.local/share/tla
curl -fL -o ~/.local/share/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
```

Set `TLA2TOOLS_JAR` to use a jar in another location. The shell scripts look for Java in `JAVA_HOME`, then in Homebrew's OpenJDK, then on `PATH`.

The SDK drivers also need Bun, the native addon, and the durable World packages:

```sh
zig build libfx-napi -Dnapi-surface=core
npm ci --prefix sdk/durable
```

## Run

From the repository root:

```sh
tests/tla/session_manager/check.sh                      # every session spec
tests/tla/session_manager/check.sh SessionLog Fork      # selected specs
tests/tla/session_manager/mutants.py                    # every planted bug must be caught
tests/tla/session_manager/trace/selftest.sh             # the trace validator must accept and reject
tests/tla/indexer/check.sh                              # every refresh config and its expected verdict
tests/tla/sdk/check.sh                                  # the SDK specs; writes the state graphs the drivers walk
bun tests/tla/drivers/drive.mjs send --walks 40         # one durable-session graph; see .github/workflows/ci.yml for the rest
bun tests/tla/drivers/drive-agents.mjs send --walks 60  # agent routing
bun tests/tla/drivers/drive-steer.mjs ideal --walks 20  # steering
```

`Fork` and `V1Conversion` can run for many minutes. `session_manager/README.md` describes each session spec, the planted bugs, and the trace checkers.
