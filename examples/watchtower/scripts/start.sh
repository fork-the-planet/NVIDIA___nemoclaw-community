#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Start the in-sandbox Watchtower scheduler. The scheduler runs inside the
# OpenShell sandbox and periodically invokes `openclaw agent` there.
#
# Usage:
#   bash scripts/start.sh [watchlist-path] [interval-seconds]
#
# Defaults:
#   watchlist-path: WATCHTOWER_WATCHLIST or watchlists/dev-ecosystem.yaml
#   interval:       WATCHTOWER_INTERVAL_SECONDS or 86400

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH — run scripts/onboard.sh first" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"
WATCHLIST="${1:-${WATCHTOWER_WATCHLIST:-watchlists/dev-ecosystem.yaml}}"
INTERVAL_SECONDS="${2:-${WATCHTOWER_INTERVAL_SECONDS:-86400}}"
RUN_ON_START="${WATCHTOWER_RUN_ON_START:-1}"

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found — run scripts/onboard.sh first" >&2
  exit 1
fi

echo "Starting Watchtower scheduler in sandbox '$NEMOCLAW_SANDBOX_NAME'"
echo "  watchlist: $WATCHLIST"
echo "  interval:  ${INTERVAL_SECONDS}s"
echo "  workspace: $WORKSPACE"

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- env \
  WATCHTOWER_WORKSPACE="$WORKSPACE" \
  WATCHTOWER_WATCHLIST="$WATCHLIST" \
  WATCHTOWER_INTERVAL_SECONDS="$INTERVAL_SECONDS" \
  WATCHTOWER_RUN_ON_START="$RUN_ON_START" \
  "$WORKSPACE/bin/watchtowerd.sh" start
