# copilot-guard

**Bluebear's zero-install governance plugin for the GitHub Copilot CLI.**

`bluebear-guard` lets a security team govern GitHub Copilot coding sessions —
monitor them and block disallowed actions — on any developer machine **without
installing anything locally**. It is the Copilot arm of [Bluebear](https://bluebear.io)'s
security platform for AI coding agents (alongside the equivalents for Claude Code and,
soon, Cursor).

## Why this exists

AI coding agents run real shell commands, read/write files, and call tools on developer
machines. Security teams need to see what those agents do and stop dangerous actions —
ideally with **nothing for each developer to install or configure**. Copilot CLI supports
hooks and enterprise-distributed plugins, so a single plugin, enabled once at the org level,
can enforce policy everywhere.

## What it does

On each Copilot CLI hook, the plugin:

1. **Captures the session** — session start, prompts, tool calls, and responses are sent to
   Bluebear's ingest so the session shows up in the console (named, attributed, counted),
   exactly like a handler-captured session — independent of whether anything is blocked.
2. **Enforces policy on `preToolUse`** — before a tool call runs, the plugin asks Bluebear
   for a decision; a `deny` blocks the tool call (Copilot's `permissionDecision: deny`) and
   shows the reason to the developer.

The developer's org is resolved server-side from their GitHub login via Bluebear's GitHub
App (Copilot-seat membership) — the plugin itself carries **no org id and no secrets**. The
enforcement mode is the org's **No-Handler Policy**: `off` (allow all), `block_all`,
`block HITL-matched`, or `custom` rules.

> If the developer's org is not a Bluebear customer, the plugin is a silent no-op
> (fail-open): a shared global plugin must never interfere with non-customers.

## How it's deployed (zero developer setup)

This is **not** a plugin developers install by hand. A security admin enables it **once**
at the org/enterprise level (Copilot AI Controls / managed settings), which registers the
`bluebear` marketplace (this repo) and enables `bluebear-guard`. Copilot then delivers it to
every seat automatically. Because Copilot pins an installed plugin's version, the guard also
**self-updates** — once per day, on session start, in the background — so shipped fixes reach
seats without manual intervention.

## How it's built

The hook logic is a single self-contained POSIX-sh library (a fresh machine is assumed to
have only `sh`, `git`, and `curl`), split by concern and shared with the Claude/Cursor
agentless libraries:

```
plugins/bluebear-guard/
  agentless/
    shared.sh     # agent-agnostic helpers  (bluebear_*)
    copilot.sh    # Copilot-specific dispatcher + helpers (copilot_*)
  hooks.json      # GENERATED — do not hand-edit
  build_hooks.py  # composes shared.sh + copilot.sh into each hook's command
  plugin.json     # plugin manifest (version)
.github/plugin/marketplace.json   # marketplace manifest (version must match)
tests/            # hook-contract + self-update behavior tests
```

`hooks.json` is regenerated from the `agentless/` sources by `build_hooks.py`; run
`python3 plugins/bluebear-guard/build_hooks.py --check` to verify it isn't stale.
`shared.sh` and `copilot.sh` are kept **byte-identical** to their copies in the Bluebear
backend so all agents share one implementation.

## Releasing

Bump **both** `plugins/bluebear-guard/plugin.json` and `.github/plugin/marketplace.json` to
the same new version — Copilot seats only pull a new build when the marketplace version
changes.

---

Questions: info@bluebear.io
