#!/bin/sh
# Model-check the fx MCP host models (src/core/mcp_host/,
# src/core/app/app_mcp_runtime.zig) with TLC.
#
# catalog.json lists each model's smoke and stress configs, its planted bugs
# (<Module>.mutants.json), and its findings configs: properties stated for
# users that the model of the code is known to break. ../drivers/mcp_host/model.ts
# runs them all and requires each verdict. Pass --model <Module> to run one.
#
# Credentials, SharedLogins, and parts of SignIn, ElicitationRouting, and
# HostLifecycle describe MCP host fixes from the next MCP-v2 version, which
# src/core/mcp_host/ does not have yet. The model checks pass either way.
#
# The tests that drive the real fx binary and have TLC check each trace:
#   bun test ../drivers/mcp_host/
#   FX_TLA_NEXT_MCP=1 bun test ../drivers/mcp_host/   # also the next-version fixes
#
# Needs Java 11+, Bun, and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/fx-tla/mcp_host"
mkdir -p "$out"
exec bun ../drivers/mcp_host/model.ts "$out" "$@"
