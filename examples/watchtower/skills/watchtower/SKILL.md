---
name: "watchtower"
description: "Run a scheduled web-surveillance sweep over a watchlist of topics using site-scoped web_search queries, deterministic dedup and domain filtering, and a cited Markdown digest. Use when the user asks to run a sweep, run a watchtower sweep, monitor the watchlist, check the watchlist, or asks what changed since the last run. Trigger keywords - run a sweep, watchtower sweep, monitor watchlist, what changed."
license: "Apache-2.0"
---

# watchtower

Sweep every topic in the active watchlist for genuinely new items, judge their
significance, and write a cited digest plus a structured changelog.

## Design principle

**The prompt suggests, the scripts enforce.** You choose search queries and
judge significance; the scripts decide — deterministically — what counts as
new and in-scope. Never re-implement dedup or domain filtering with your own
judgment: always pipe candidates through `diff_state.py`, and always advance
state through `commit_state.py`.

Hard rules:

- Never fabricate URLs. Cite only URLs returned by `web_search` in this run.
- Never cite or digest a source outside the topic's `domains` list.
- If you need page text beyond the `web_search` snippet, fetch only surviving on-domain URLs with `tavily_extract`. Never fetch result URLs with `web_fetch`, browser tools, `curl`, or custom HTTP scripts.
- Never advance state before both output files are written.

## Run identity

Set a run id at the start of the sweep: UTC date plus a short random suffix,
e.g. `2026-07-06-k3f9`. Use it in both output filenames and in every item
committed to state.

## Procedure

### 1. Validate the active watchlist

```bash
python3 ~/.openclaw/skills/watchtower/scripts/validate_watchlist.py watchlists/dev-ecosystem.yaml
```

If validation fails, stop and report the error. Do not sweep an invalid
watchlist.

### 2. Search each topic (site-scoped)

For each topic, run 1-2 `web_search` queries built from the topic's `query`
and scoped to its `domains` with `site:` operators, for example:

```text
new Nemotron model release announcement site:huggingface.co OR site:developer.nvidia.com
```

The `site:` scoping is a suggestion to the search engine — off-domain results
can still come back. That is fine; the domain rule is enforced in step 3.

### 3. Collect candidates and filter deterministically

Collect every result as a JSON line with fields `topic_id`, `url`, `title`,
then pipe the batch through `diff_state.py`:

```bash
<candidates.jsonl python3 ~/.openclaw/skills/watchtower/scripts/diff_state.py \
  --watchlist watchlists/dev-ecosystem.yaml \
  --state state/seen.json >survivors.jsonl
```

Only items that are unseen AND on-domain survive. Everything dropped here is
dropped for good reason — do not resurrect filtered items.

### 4. Extract and judge survivors only

For each surviving item, judge its significance against the topic's
`why_it_matters`. Use the title and snippet/content returned by `web_search`;
when you need fuller page text, call `tavily_extract` on the surviving URL.
Do not extract anything that did not survive `diff_state.py`. Assign `high`,
`medium`, or `low`.

If an item is real but noise (a minor patch note, a duplicate announcement of
something already digested under another URL, an incidental page match), log
it as skipped with a one-line reason instead of digesting it. When in doubt,
include it as `low` rather than omitting it silently.

### 5. Write the digest and changelog

Write both files before touching state:

- `outputs/digest-<run-id>.md` — per topic: what changed, why it matters
  (grounded in the topic's `why_it_matters`), and source links. If no topic
  produced anything new, write a short "no changes" digest saying which
  topics were swept.
- `outputs/changelog-<run-id>.json` — a JSON array of
  `{topic_id, url, title, significance, summary}` for every digested item
  (empty array when nothing changed).

### 6. Commit state — only after both outputs exist

Pipe the digested items (now including `run_id`) to `commit_state.py`:

```bash
<confirmed.jsonl python3 ~/.openclaw/skills/watchtower/scripts/commit_state.py --state state/seen.json
```

This ordering is the crash-safety contract: if the run dies before step 6,
state has not advanced and the next sweep re-processes the same candidates
instead of losing them. A re-processed item is cheap; a silently lost item is
not.
