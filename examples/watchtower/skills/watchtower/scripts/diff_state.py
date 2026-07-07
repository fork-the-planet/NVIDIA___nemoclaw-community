#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Deterministically filter watchtower candidate items against seen-state and watchlist domains.

Reads candidate items as JSON lines on stdin (fields: topic_id, url, title).
Drops any item whose URL is already recorded in the state file, or whose host
is not within that item's topic's allowed domains (subdomain suffix match).
Surviving items are emitted as JSON lines on stdout, unchanged.

This script makes no network calls and no significance judgment — it only
enforces the dedup and domain rules the watchtower skill prompt describes.
The prompt suggests which queries to run; this script enforces what counts
as new and in-scope. See skills/watchtower/SKILL.md.

Usage:
    <candidates.jsonl python3 diff_state.py --watchlist <path> --state <path> >survivors.jsonl
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

_TOPIC_START_RE = re.compile(r"^\s*-\s*id:\s*(.+)$")
_DOMAINS_FIELD_RE = re.compile(r"^\s+domains:\s*(.*)$")


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _parse_domains(raw: str) -> list[str]:
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    return [_strip_quotes(d) for d in raw.split(",") if _strip_quotes(d)]


def load_topic_domains(watchlist_path: Path) -> dict[str, list[str]]:
    """Extract {topic_id: [domains]} from a watchlist YAML file.

    Uses the same restricted line-based reading as validate_watchlist.py.
    Run validate_watchlist.py first — this assumes a schema-valid file.
    """
    domains_by_topic: dict[str, list[str]] = {}
    current_id: str | None = None
    for line in watchlist_path.read_text(encoding="utf-8").splitlines():
        topic_start = _TOPIC_START_RE.match(line)
        if topic_start:
            current_id = _strip_quotes(topic_start.group(1))
            continue
        domains_field = _DOMAINS_FIELD_RE.match(line)
        if domains_field and current_id is not None:
            domains_by_topic[current_id] = _parse_domains(domains_field.group(1))
    return domains_by_topic


def load_seen_urls(state_path: Path) -> set[str]:
    if not state_path.is_file():
        return set()
    text = state_path.read_text(encoding="utf-8").strip()
    if not text:
        return set()
    state = json.loads(text)
    return {item["url"] for item in state.get("items", [])}


def host_in_domains(host: str, domains: list[str]) -> bool:
    host = host.lower()
    for domain in domains:
        domain = domain.lower()
        if host == domain or host.endswith("." + domain):
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Filter candidate items on stdin (JSON lines: topic_id, url, title) against "
            "seen-state and watchlist domain rules. Surviving items are written to stdout "
            "as JSON lines, one per line, unchanged."
        ),
    )
    parser.add_argument("--watchlist", required=True, type=Path, help="Path to the active watchlist YAML file")
    parser.add_argument("--state", required=True, type=Path, help="Path to the seen-items state JSON file")
    args = parser.parse_args()

    if not args.watchlist.is_file():
        print(f"error: watchlist file not found: {args.watchlist}", file=sys.stderr)
        return 1

    domains_by_topic = load_topic_domains(args.watchlist)
    seen_urls = load_seen_urls(args.state)

    survivors = 0
    for lineno, raw_line in enumerate(sys.stdin, start=1):
        line = raw_line.strip()
        if not line:
            continue

        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            print(f"error: stdin line {lineno}: invalid JSON: {exc}", file=sys.stderr)
            return 1

        topic_id = item.get("topic_id")
        url = item.get("url")
        if not topic_id or not url:
            print(f"warning: stdin line {lineno}: missing topic_id or url, skipping", file=sys.stderr)
            continue

        domains = domains_by_topic.get(topic_id)
        if domains is None:
            print(f"warning: stdin line {lineno}: unknown topic_id '{topic_id}', skipping", file=sys.stderr)
            continue

        if url in seen_urls:
            continue

        host = urlparse(url).hostname or ""
        if not host_in_domains(host, domains):
            continue

        print(json.dumps(item))
        survivors += 1

    print(f"diff_state: {survivors} item(s) survived dedup + domain filtering", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
