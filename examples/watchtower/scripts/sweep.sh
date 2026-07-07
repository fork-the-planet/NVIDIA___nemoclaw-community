#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# One-shot watchtower sweep: sends the sweep prompt to the OpenClaw agent in
# a single non-interactive turn. The in-sandbox scheduler uses the same sweep
# path via runtime/watchtowerd.sh; this script remains useful for ad-hoc runs.
#
# Usage:
#   bash scripts/sweep.sh [watchlist-path]
#
# The watchlist path is relative to the agent workspace inside the sandbox
# (default: watchlists/dev-ecosystem.yaml). Override the sandbox with
# NEMOCLAW_SANDBOX_NAME (default: watchtower).

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH — run scripts/onboard.sh first" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"
WATCHLIST="${1:-${WATCHTOWER_WATCHLIST:-watchlists/dev-ecosystem.yaml}}"

echo "Sweeping $WATCHLIST in sandbox '$NEMOCLAW_SANDBOX_NAME'"
# No --local: NemoClaw sandboxes reject it (it would bypass the gateway's
# managed inference route, secret scanning, and network policy).
run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- env \
  WATCHTOWER_WORKSPACE="$WORKSPACE" \
  WATCHTOWER_WATCHLIST="$WATCHLIST" \
  bash -lc '
    if [ -x "$WATCHTOWER_WORKSPACE/bin/watchtowerd.sh" ]; then
      "$WATCHTOWER_WORKSPACE/bin/watchtowerd.sh" once
    else
      openclaw agent --agent main -m "Run a watchtower sweep of $WATCHTOWER_WATCHLIST."
    fi
  '
