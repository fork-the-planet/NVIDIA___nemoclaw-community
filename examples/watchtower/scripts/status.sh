#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Show scheduler status, recent scheduler logs, and latest output artifacts.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"
WATCHLIST="${WATCHTOWER_WATCHLIST:-watchlists/dev-ecosystem.yaml}"
INTERVAL_SECONDS="${WATCHTOWER_INTERVAL_SECONDS:-86400}"

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found" >&2
  exit 1
fi

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- env \
  WATCHTOWER_WORKSPACE="$WORKSPACE" \
  WATCHTOWER_WATCHLIST="$WATCHLIST" \
  WATCHTOWER_INTERVAL_SECONDS="$INTERVAL_SECONDS" \
  "$WORKSPACE/bin/watchtowerd.sh" status
