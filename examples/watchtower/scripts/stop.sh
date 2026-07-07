#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Remove Watchtower OpenClaw Cron Jobs. With no argument, removes every job
# whose name starts with "watchtower-". Pass a specific job name to remove only
# that job.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"
HELPER="$WORKSPACE/bin/openclaw-cron-rpc.mjs"
JOB_SELECTOR="${1:-${WATCHTOWER_JOB_NAME:-watchtower-}}"

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found" >&2
  exit 1
fi

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- mkdir -p "$WORKSPACE/bin"
run openshell sandbox upload "$NEMOCLAW_SANDBOX_NAME" "$EXAMPLE_DIR/runtime/openclaw-cron-rpc.mjs" "$WORKSPACE/bin/"
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- chmod +x "$HELPER"

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- \
  node "$HELPER" remove-matching --name "$JOB_SELECTOR"
