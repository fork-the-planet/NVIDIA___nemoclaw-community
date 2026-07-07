#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Tiny in-sandbox scheduler for Watchtower. It intentionally avoids depending
# on cron/systemd being installed in the sandbox: one long-lived process sleeps,
# invokes one OpenClaw sweep, and writes logs/state under the agent workspace.

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
WORKSPACE="${WATCHTOWER_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WATCHLIST="${WATCHTOWER_WATCHLIST:-watchlists/dev-ecosystem.yaml}"
INTERVAL_SECONDS="${WATCHTOWER_INTERVAL_SECONDS:-86400}"
RUN_ON_START="${WATCHTOWER_RUN_ON_START:-1}"

RUN_DIR="$WORKSPACE/run"
LOG_DIR="$WORKSPACE/logs"
OUTPUT_DIR="$WORKSPACE/outputs"
STATE_DIR="$WORKSPACE/state"
PID_FILE="$RUN_DIR/watchtowerd.pid"
CONFIG_FILE="$RUN_DIR/watchtowerd.env"
STOP_FILE="$RUN_DIR/watchtowerd.stop"
LOCK_DIR="$RUN_DIR/sweep.lock"
LOG_FILE="$LOG_DIR/watchtowerd.log"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$OUTPUT_DIR" "$STATE_DIR"

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$INTERVAL_SECONDS" -lt 1 ]]; then
  echo "error: WATCHTOWER_INTERVAL_SECONDS must be a positive integer, got '$INTERVAL_SECONDS'" >&2
  exit 1
fi

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(timestamp)] $*"
}

pid_is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

run_sweep() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "sweep skipped: another sweep is already running ($LOCK_DIR exists)"
    return 0
  fi

  local rc=0
  {
    echo "pid=$$"
    echo "started=$(timestamp)"
    echo "watchlist=$WATCHLIST"
  } >"$LOCK_DIR/meta"

  log "sweep starting: $WATCHLIST"
  (
    cd "$WORKSPACE"
    openclaw agent --agent main -m "Run a watchtower sweep of $WATCHLIST."
  ) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    log "sweep finished successfully: $WATCHLIST"
  else
    log "sweep failed with exit code $rc: $WATCHLIST"
  fi
  rm -rf "$LOCK_DIR"
  return "$rc"
}

sleep_with_stop_check() {
  local remaining="$1"
  local chunk
  while [[ "$remaining" -gt 0 ]]; do
    if [[ -f "$STOP_FILE" ]]; then
      return 1
    fi
    chunk=30
    if [[ "$remaining" -lt "$chunk" ]]; then
      chunk="$remaining"
    fi
    sleep "$chunk"
    remaining=$((remaining - chunk))
  done
  return 0
}

cmd_start() {
  if pid_is_running; then
    echo "watchtowerd already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  rm -f "$STOP_FILE"
  nohup "$SCRIPT_PATH" run >>"$LOG_FILE" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" >"$PID_FILE"
  disown "$pid" 2>/dev/null || true
  sleep 1

  if pid_is_running; then
    echo "watchtowerd started (pid $(cat "$PID_FILE"))"
    echo "log: $LOG_FILE"
  else
    echo "watchtowerd failed to start; see $LOG_FILE" >&2
    exit 1
  fi
}

cmd_run() {
  echo "$$" >"$PID_FILE"
  {
    echo "workspace=$WORKSPACE"
    echo "watchlist=$WATCHLIST"
    echo "interval_seconds=$INTERVAL_SECONDS"
    echo "run_on_start=$RUN_ON_START"
    echo "started=$(timestamp)"
  } >"$CONFIG_FILE"
  trap 'rm -f "$PID_FILE"' EXIT
  rm -f "$STOP_FILE"

  log "watchtowerd running: workspace=$WORKSPACE watchlist=$WATCHLIST interval=${INTERVAL_SECONDS}s run_on_start=$RUN_ON_START"

  if [[ "$RUN_ON_START" != "0" ]]; then
    run_sweep || true
  fi

  while true; do
    log "next sweep in ${INTERVAL_SECONDS}s"
    if ! sleep_with_stop_check "$INTERVAL_SECONDS"; then
      log "stop requested; exiting"
      rm -f "$STOP_FILE"
      exit 0
    fi
    run_sweep || true
  done
}

cmd_stop() {
  if ! pid_is_running; then
    rm -f "$PID_FILE" "$STOP_FILE"
    echo "watchtowerd is not running"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  touch "$STOP_FILE"
  echo "stop requested for watchtowerd (pid $pid)"

  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE" "$STOP_FILE"
      echo "watchtowerd stopped"
      exit 0
    fi
    sleep 1
  done

  echo "watchtowerd is still running; it may be finishing the current sweep"
  echo "log: $LOG_FILE"
}

cmd_status() {
  if pid_is_running; then
    echo "status: running"
    echo "pid: $(cat "$PID_FILE")"
  else
    echo "status: stopped"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    sed 's/^/config: /' "$CONFIG_FILE"
  else
    echo "workspace: $WORKSPACE"
    echo "watchlist: $WATCHLIST"
    echo "interval_seconds: $INTERVAL_SECONDS"
  fi
  echo "log: $LOG_FILE"

  local latest_digest latest_changelog
  latest_digest="$(ls -t "$OUTPUT_DIR"/digest-* 2>/dev/null | head -n 1 || true)"
  latest_changelog="$(ls -t "$OUTPUT_DIR"/changelog-* 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest_digest" ]] && echo "latest_digest: $latest_digest"
  [[ -n "$latest_changelog" ]] && echo "latest_changelog: $latest_changelog"

  if [[ -d "$LOCK_DIR" ]]; then
    echo "current_sweep: running"
    [[ -f "$LOCK_DIR/meta" ]] && sed 's/^/  /' "$LOCK_DIR/meta"
  fi

  if [[ -f "$LOG_FILE" ]]; then
    echo
    echo "recent log:"
    tail -n 20 "$LOG_FILE"
  fi
}

case "${1:-status}" in
  start) cmd_start ;;
  run) cmd_run ;;
  once) run_sweep ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {start|run|once|stop|status}" >&2
    exit 2
    ;;
esac
