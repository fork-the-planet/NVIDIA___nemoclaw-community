#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Stop the in-sandbox Watchtower scheduler. If a sweep is currently running,
# the scheduler exits after that sweep finishes.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/_lib.sh"

command -v openshell >/dev/null || { echo "openshell not in PATH" >&2; exit 1; }

WORKSPACE="${WORKSPACE:-/sandbox/.openclaw/workspace}"

if ! sandbox_exists "$NEMOCLAW_SANDBOX_NAME"; then
  echo "Sandbox '$NEMOCLAW_SANDBOX_NAME' not found" >&2
  exit 1
fi

run openshell sandbox exec --name "$NEMOCLAW_SANDBOX_NAME" -- env \
  WATCHTOWER_WORKSPACE="$WORKSPACE" \
  "$WORKSPACE/bin/watchtowerd.sh" stop
