#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Show OpenClaw Cron Job status, registered jobs, recent run history, and latest
# Watchtower output artifacts.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"
HELPER="$WORKSPACE/bin/openclaw-cron-rpc.mjs"

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found" >&2
  exit 1
fi

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- mkdir -p "$WORKSPACE/bin"
run openshell sandbox upload "$NEMOCLAW_SANDBOX_NAME" "$EXAMPLE_DIR/runtime/openclaw-cron-rpc.mjs" "$WORKSPACE/bin/"
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- chmod +x "$HELPER"

echo "== OpenClaw cron scheduler =="
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- node "$HELPER" status || true

echo
echo "== Cron jobs =="
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- node "$HELPER" list || true

echo
echo "== Recent cron runs =="
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- node "$HELPER" runs --limit 20 || true

echo
echo "== Watchtower outputs =="
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- sh -lc \
  "latest_digest=\$(ls -t '$WORKSPACE'/outputs/digest-* 2>/dev/null | head -n 1 || true); latest_changelog=\$(ls -t '$WORKSPACE'/outputs/changelog-* 2>/dev/null | head -n 1 || true); [ -n \"\$latest_digest\" ] && echo latest_digest: \"\$latest_digest\" || echo latest_digest: n/a; [ -n \"\$latest_changelog\" ] && echo latest_changelog: \"\$latest_changelog\" || echo latest_changelog: n/a"
