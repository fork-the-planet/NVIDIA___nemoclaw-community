#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Create an OpenClaw-native Cron Job for Watchtower. This is the auditable
# scheduler shown in the OpenClaw dashboard under "Cron Jobs" — not host cron
# and not a custom background loop.
#
# Usage:
#   bash scripts/start.sh [watchlist-path] [every]
#
# Examples:
#   bash scripts/start.sh watchlists/regulatory.yaml 24h
#   bash scripts/start.sh watchlists/regulatory.yaml 5m
#   bash scripts/start.sh watchlists/regulatory.yaml 300   # converted to 5m

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH — run scripts/onboard.sh first" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"

WATCHLIST="${1:-${WATCHTOWER_WATCHLIST:-watchlists/regulatory.yaml}}"
EVERY_RAW="${2:-${WATCHTOWER_EVERY:-24h}}"
TIMEOUT_SECONDS="${WATCHTOWER_TIMEOUT_SECONDS:-900}"

slugify() {
  local value="$1"
  value="$(basename "$value")"
  value="${value%.*}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

format_every() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    if (( value % 3600 == 0 )); then
      printf '%sh' "$((value / 3600))"
    elif (( value % 60 == 0 )); then
      printf '%sm' "$((value / 60))"
    else
      printf '%ss' "$value"
    fi
  else
    printf '%s' "$value"
  fi
}

JOB_NAME="${WATCHTOWER_JOB_NAME:-watchtower-$(slugify "$WATCHLIST")}"
EVERY="$(format_every "$EVERY_RAW")"
MESSAGE="Run a watchtower sweep of $WATCHLIST."

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found — run scripts/onboard.sh first" >&2
  exit 1
fi

echo "Creating OpenClaw Cron Job in sandbox '$NEMOCLAW_SANDBOX_NAME'"
echo "  job:       $JOB_NAME"
echo "  watchlist: $WATCHLIST"
echo "  every:     $EVERY"
echo "  workspace: $WORKSPACE"

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- mkdir -p "$WORKSPACE/bin"
run openshell sandbox upload "$NEMOCLAW_SANDBOX_NAME" "$EXAMPLE_DIR/runtime/openclaw-cron-rpc.mjs" "$WORKSPACE/bin/"
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- chmod +x "$WORKSPACE/bin/openclaw-cron-rpc.mjs"
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- \
  node "$WORKSPACE/bin/openclaw-cron-rpc.mjs" add \
    --name "$JOB_NAME" \
    --agent main \
    --every "$EVERY" \
    --message "$MESSAGE" \
    --timeoutSeconds "$TIMEOUT_SECONDS"

echo
echo "Created. Inspect it in the OpenClaw dashboard under Cron Jobs, or run:"
echo "  bash scripts/status.sh"
