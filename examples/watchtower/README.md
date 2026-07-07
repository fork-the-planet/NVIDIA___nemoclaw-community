# Watchtower: Scheduled Web Surveillance with Tavily

Watchtower is an unattended web-surveillance agent built on the NemoClaw
OpenClaw harness. A `watchlist.yaml` defines the topics to monitor and the
authoritative domains for each topic. An OpenClaw Cron Job periodically invokes
the agent; each sweep runs site-scoped `web_search` queries (Tavily provider),
deterministically diffs the results against a persistent seen-items state file,
judges the significance of only the genuinely new items, and writes a cited
Markdown digest plus a structured JSON changelog to `outputs/`. State advances
only after the digest is written, so a crashed run re-processes items on the
next sweep instead of losing them.

The design principle throughout: **the prompt suggests, the scripts
enforce**. Dedup and domain filtering are deterministic Python — never LLM
judgment. The LLM's judgment is confined to the one question it is good at
and a script cannot answer: how significant is a genuinely new item, given
why the topic is being watched.

## Architecture

```mermaid
flowchart LR

    tavily["External\napi.tavily.com\n(web search)"]
    llm["External\nLLM Inference Provider\n(OpenAI-compatible)"]

    subgraph host["Host Machine"]
        direction TB

        subgraph supervisor["OpenShell Sandbox Supervisor"]
            direction TB

            l7["OpenShell L7 Proxy\n(deny-by-default egress ·\nTAVILY_API_KEY placeholder\nsubstituted on egress)"]

            subgraph sandbox["OpenShell Sandbox"]
                direction TB

                cron["OpenClaw Cron Job\nauditable schedule"]
                agent["OpenClaw Agent\nAGENTS.md identity"]

                subgraph skill["watchtower skill"]
                    direction TB
                    s1["validate_watchlist.py"]
                    s2["diff_state.py"]
                    s3["commit_state.py"]
                end

                wl[("watchlists/\n*.yaml")]
                st[("state/seen.json")]
                out[("outputs/\ndigest · changelog")]
                runs[("Cron Jobs UI\nrun history")]

                cron -->|"periodic\nagent message"| agent
                cron --> runs

                agent -->|"built-in web_search\n(provider: tavily)"| l7
                agent -->|"script dispatch"| skill
                skill --> wl
                skill --> st
                agent --> out
            end
        end

        gateway["OpenShell Gateway\nprovider store\n(real TAVILY_API_KEY)"]
        gateway <--> l7
    end

    l7 -->|"HTTPS POST\nsearch queries"| tavily
    agent -->|"HTTPS POST\nLLM inference"| llm

    style sandbox fill:#1a237e,stroke:#3949ab,stroke-width:2px,color:#fff
    style skill   fill:#283593,stroke:#5c6bc0,stroke-width:1px,color:#fff
    style agent   fill:#283593,stroke:#5c6bc0,stroke-width:1px,color:#fff
    style cron fill:#283593,stroke:#5c6bc0,stroke-width:1px,color:#fff
    style l7      fill:#e7f0ff,stroke:#2b5fab,stroke-width:2px,color:#111
    style tavily  fill:#7b1fa2,stroke:#9c27b0,stroke-width:2px,color:#fff
    style llm     fill:#1a1a2e,stroke:#76b900,stroke-width:2px,color:#76b900
```

The sandbox's only research egress is `api.tavily.com`, through the OpenShell
L7 proxy. The Tavily API key lives in the OpenShell provider store on the
host; inside the sandbox the agent only ever sees the canonical placeholder
`openshell:resolve:env:TAVILY_API_KEY`, which the proxy substitutes on
egress. The real key never enters the sandbox.

## How it works

Each sweep follows the procedure in
[`skills/watchtower/SKILL.md`](skills/watchtower/SKILL.md):

1. **Validate** — `validate_watchlist.py` fail-fast checks the active
   watchlist schema (every topic needs `id`, `query`, non-empty `domains`,
   `why_it_matters`). An invalid watchlist stops the run before any search.
2. **Search** — per topic, the agent runs 1-2 `web_search` queries built from
   the topic's `query` and scoped with `site:` operators from its `domains`,
   e.g. `new Nemotron model release announcement site:huggingface.co OR
   site:developer.nvidia.com`.
3. **Diff** — every result is collected as a JSON line
   (`topic_id`, `url`, `title`) and piped through `diff_state.py`, which
   deterministically drops anything already in `state/seen.json` or whose
   host is not within the topic's domains (subdomain suffix match). `site:`
   scoping is a suggestion to the search engine; this filter is the
   enforcement.
4. **Extract + judge** — only the survivors reach the LLM. If the search
   snippet is not enough, the agent uses `tavily_extract` on those surviving
   on-domain URLs, then rates significance against the topic's
   `why_it_matters`. Noise is logged as skipped with a one-line reason instead
   of digested.
5. **Write** — the agent writes `outputs/digest-<run-id>.md` (per topic: what
   changed, why it matters, source links — or a short "no changes" digest)
   and `outputs/changelog-<run-id>.json` (array of
   `{topic_id, url, title, significance, summary}`).
6. **Commit** — only after both files exist, the digested items are piped to
   `commit_state.py`, which appends them to `state/seen.json` atomically
   (write temp + rename). If the run crashes before this step, state has not
   advanced and the next sweep re-processes the same candidates.

Sample output from a sweep is checked in under
[`outputs/sample/`](outputs/sample/).

## Setup

### Prerequisites

- A Linux host with Docker (see the
  [NemoClaw prerequisites](https://docs.nvidia.com/nemoclaw/)).
- NemoClaw installed. If `nemoclaw` is not on your PATH yet, install it —
  the acceptance variable must be on the `bash` side of the pipe:

  ```bash
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash
  ```

- A `TAVILY_API_KEY` (from <https://app.tavily.com>) and credentials for an
  inference path with tool calling — NVIDIA Endpoints
  (`NVIDIA_INFERENCE_API_KEY` from <https://build.nvidia.com>) or any
  OpenAI-compatible endpoint. See [`.env.example`](.env.example).

### Scripted setup

```bash
git clone https://github.com/NVIDIA/nemoclaw-community.git
cd nemoclaw-community/examples/watchtower

cp .env.example .env      # then edit: TAVILY_API_KEY + inference credentials
bash scripts/onboard.sh   # non-interactive `nemoclaw onboard`, Tavily web search
bash scripts/install.sh   # push skill, watchlists, AGENTS.md into the sandbox
bash scripts/start.sh     # create the auditable OpenClaw Cron Job
```

`scripts/onboard.sh` scripts *through* `nemoclaw onboard --non-interactive`:
it exports `NEMOCLAW_WEB_SEARCH_PROVIDER=tavily` and your `.env` answers,
then hands off to the wizard. That single onboarding step provides
everything Watchtower needs from the platform: the built-in `web_search`
tool wired to the Tavily provider, the key stored as an OpenShell provider
placeholder, and the Tavily egress policy on the sandbox. The script is
idempotent — if the sandbox already exists it prints its status and exits.

`scripts/install.sh` uses `openshell sandbox upload` to place the skill at
`/sandbox/.openclaw/skills/watchtower/`, the watchlists and `AGENTS.md` in
the agent workspace, and creates empty `state/` and `outputs/` directories.
Override the workspace for named agents with
`WORKSPACE=/sandbox/.openclaw/workspace-main`, and the sandbox name with
`NEMOCLAW_SANDBOX_NAME` (default `watchtower`).

### Manual path (the moving parts)

The scripts do nothing you cannot do by hand:

```bash
export NEMOCLAW_WEB_SEARCH_PROVIDER=tavily TAVILY_API_KEY=<your-key>
export NEMOCLAW_PROVIDER=build NVIDIA_INFERENCE_API_KEY=<your-key>
export NEMOCLAW_SANDBOX_NAME=watchtower
nemoclaw onboard --non-interactive

openshell sandbox exec --name watchtower -- mkdir -p \
  /sandbox/.openclaw/skills/watchtower /sandbox/.openclaw/workspace/watchlists \
  /sandbox/.openclaw/workspace/state /sandbox/.openclaw/workspace/outputs
openshell sandbox upload watchtower skills/watchtower/ /sandbox/.openclaw/skills/watchtower/
openshell sandbox upload watchtower watchlists/ /sandbox/.openclaw/workspace/watchlists/
openshell sandbox upload watchtower prompts/AGENTS.md /sandbox/.openclaw/workspace/
openshell sandbox exec --name watchtower -- \
  openclaw cron add --name watchtower-dev-ecosystem --agent main \
    --session isolated --every 24h --no-deliver --timeout-seconds 900 \
    --message "Run a watchtower sweep of watchlists/dev-ecosystem.yaml."
```

`watchlists/dev-ecosystem.yaml` is the default preset used in the demo below;
`watchlists/regulatory.yaml` is a second preset you can swap in (see
[Watchlists](#watchlists)).

## Running one sweep

Run a sweep in three stages to see the state machine work:

**1. Fresh state → baseline digest.** With no `state/seen.json`, everything
the search finds is new:

```bash
bash scripts/sweep.sh
```

The agent writes `outputs/digest-<run-id>.md` with every on-domain item it
found, and `state/seen.json` now records them.

**2. Immediate re-run → "no changes", proving dedup.** Run the same command
again right away:

```bash
bash scripts/sweep.sh
```

The same search results come back, but `diff_state.py` drops them all as
already seen — the digest is a short "no changes" report. The dedup is
deterministic script output, not the LLM remembering.

**3. Restore the example state → realistic incremental digest.** Replace the
state file with the checked-in fixture, which is pre-seeded with a handful of
already-seen items for the dev-ecosystem topics:

```bash
openshell sandbox upload watchtower state/seen.json.example /sandbox/.openclaw/workspace/state/
openshell sandbox exec --name watchtower -- mv \
  /sandbox/.openclaw/workspace/state/seen.json.example \
  /sandbox/.openclaw/workspace/state/seen.json
```

Then run `bash scripts/sweep.sh` once more. Now the run produces what a
steady-state scheduled run looks like: older releases are filtered as seen,
and only items newer than the fixture appear in the digest.

`scripts/sweep.sh` takes an optional watchlist path (relative to the agent
workspace) as its first argument, e.g.
`bash scripts/sweep.sh watchlists/regulatory.yaml`.

## Scheduling

Create an OpenClaw Cron Job:

```bash
bash scripts/start.sh
```

By default this creates a `watchtower-dev-ecosystem` job that runs every 24
hours. The schedule and run history are visible in the OpenClaw dashboard's
**Cron Jobs** page; the host scripts are only convenience wrappers:

```bash
bash scripts/status.sh   # cron scheduler status, jobs, recent runs, latest outputs
bash scripts/stop.sh     # remove Watchtower cron jobs
```

Use another watchlist or interval with arguments:

```bash
bash scripts/start.sh watchlists/regulatory.yaml 5m
```

Integer intervals are accepted for convenience and converted to OpenClaw
durations, so `300` becomes `5m`:

```bash
bash scripts/start.sh watchlists/regulatory.yaml 300
```

Or set the same defaults in `.env`:

```env
WATCHTOWER_WATCHLIST=watchlists/dev-ecosystem.yaml
WATCHTOWER_EVERY=24h
WATCHTOWER_TIMEOUT_SECONDS=900
WATCHTOWER_JOB_NAME=watchtower-dev-ecosystem
```

Because state only advances after a digest is written, a run that fails
mid-sweep (endpoint outage, sandbox restart) simply re-processes the same
items on the next scheduled run — no items are lost and no manual state repair
is needed.

## Watchlists

A watchlist is a YAML file with one required top-level name and a list of
topics:

```yaml
watchlist: dev-ecosystem
topics:
  - id: nemotron-releases
    query: "new Nemotron model release announcement"
    domains: [huggingface.co, developer.nvidia.com]
    why_it_matters: "Track new model drops relevant to NemoClaw users"
```

Per topic:

| Key | Purpose |
|---|---|
| `id` | Stable identifier; used in state, digests, and changelogs. Do not rename an id casually — state entries are keyed to it. |
| `query` | The search intent, phrased for a web search engine. |
| `domains` | The only acceptable source hosts for this topic. Subdomains match (a result on `download.pytorch.org` is within `pytorch.org`). Enforced by `diff_state.py`, not by the prompt. |
| `why_it_matters` | The significance yardstick the LLM judges new items against, and the "why it matters" line in digests. |

To edit, change the YAML and re-run — `validate_watchlist.py` runs at the
start of every sweep and fails fast on schema violations. To monitor a
different domain entirely, swap the preset:
[`watchlists/regulatory.yaml`](watchlists/regulatory.yaml) tracks EU PFAS
restriction updates (`echa.europa.eu`), OFAC sanctions designations
(`ofac.treasury.gov`), and FDA device recalls (`fda.gov`). Presets share one
state file safely — state items are keyed by topic id and URL — but if you
want independent sweep histories, point each preset's runs at its own
`--state` path.

## Security model

- **Deny-by-default egress.** The sandbox reaches nothing except what its
  policy names. For research, that is exactly one host: `api.tavily.com`
  through the L7 proxy. Tavily is the agent's only window to the web —
  there is no direct page fetching and no other outbound route.
- **The key never enters the sandbox.** The Tavily API key is stored in the
  OpenShell provider store on the host. Inside the sandbox, requests carry
  the placeholder `openshell:resolve:env:TAVILY_API_KEY`; the L7 proxy
  substitutes the real key on egress. A fully compromised sandbox can spend
  your search quota but cannot exfiltrate the credential.
- **Scope is enforced, not requested.** `site:` operators steer the search
  engine, but the guarantee that digests only cite watchlist domains comes
  from `diff_state.py` — a deterministic filter the LLM cannot talk its way
  around. The same applies to dedup: "is this new?" is answered by the state
  file, never by model memory.
- **Crash-safe state.** `commit_state.py` writes atomically
  (temp file + rename) and runs only after outputs exist, so no failure mode
  leaves the state file corrupt or silently skips items.
