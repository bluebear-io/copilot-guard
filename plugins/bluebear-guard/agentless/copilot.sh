# Copilot-specific agentless hook functions + dispatcher (POSIX sh).
#
# Composed with shared.sh (shared.sh + copilot.sh) to form the deployed Copilot guard
# library, inlined into hooks.json; every hook runs `<lib>; copilot_main <Dispatch>`.
# Calls the shared bluebear_* helpers plus its own copilot_* functions.
#
# POSIX sh only — no bashisms, no `local`.

# Developer's GitHub login — Copilot CLI is GitHub-authenticated, so `gh` is present/authed.
# The BE resolves the org from this login (the shared global plugin carries no org id).
copilot_gh_login() {
  # Use the GitHub login Copilot itself is authenticated as (the Copilot-seat identity),
  # read from Copilot's own config. `gh api user` can resolve a DIFFERENT logged-in gh
  # account on multi-account machines, which won't match the developer's Copilot seat and
  # breaks org resolution (â "Unrecognized organization" â fail-open allow). Fall back to
  # gh only when Copilot's config login is unavailable.
  BB_CP="$HOME/.copilot/config.json"
  if [ -r "$BB_CP" ]; then
    BB_L=$(sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BB_CP" 2>/dev/null | head -n1)
    [ -n "$BB_L" ] && { printf '%s' "$BB_L"; return 0; }
  fi
  command -v gh >/dev/null 2>&1 || return 0
  gh api user --jq .login 2>/dev/null
}

# Copilot's flat deny shape (Copilot expects permissionDecision at top level, unlike Claude's
# hookSpecificOutput envelope). $1 = reason.
copilot_emit_deny() {
  printf '{"permissionDecision":"deny","permissionDecisionReason":"%s"}' "$(bluebear_json_escape "$1")"
}

# Best-effort self-update (Copilot-specific). Copilot CLI pins an installed plugin to its
# version and never re-checks the marketplace, so a shipped guard fix wouldn't reach existing
# seats without a manual `copilot plugin update`. Called ONLY from the sessionStart hook and
# throttled to once per calendar day via a state file, so it costs at most one backgrounded
# subprocess per machine per day — never on a tool call. Fully non-blocking (backgrounded,
# output discarded) so it can never delay a session or influence a deny decision, and
# PATH-guarded so it silently no-ops where `copilot` isn't resolvable. The attempt date is
# recorded BEFORE spawning, so a hung/failed update won't retry until the next day. The pull
# takes effect on the NEXT session (the current one already loaded its hooks). Uses the shared
# ~/.bluebear-agentless state dir; the file name is the operator-visible "last attempt" record.
copilot_self_update() {
  command -v copilot >/dev/null 2>&1 || return 0
  BB_SDIR="$HOME/.bluebear-agentless"
  mkdir -p "$BB_SDIR" 2>/dev/null
  BB_UF="$BB_SDIR/.plugin-update-day"
  BB_TODAY=$(date +%Y-%m-%d 2>/dev/null) || return 0
  [ -n "$BB_TODAY" ] || return 0
  [ "$(cat "$BB_UF" 2>/dev/null)" = "$BB_TODAY" ] && return 0
  printf '%s' "$BB_TODAY" >"$BB_UF" 2>/dev/null
  ( copilot plugin update bluebear-guard@bluebear </dev/null >/dev/null 2>&1 & ) 2>/dev/null
}

# --- Copilot dispatcher ---------------------------------------------------------------------
# The Copilot guardrails plugin is ONE global plugin shared across all customers, so it carries
# no org id (unlike Claude's per-org managed-settings). We enrich from the local machine
# (github_login, developer_email, git) into the handler Envelope shape; the ingest endpoint
# resolves the org from github_login. Shares every helper + the prompt_id state with claude_main.
# Copilot input differs: `sessionId`/`toolName`/`toolArgs`(a JSON string)/`cwd`, and Copilot
# expects the flat `{"permissionDecision":"deny"}` shape (copilot_emit_deny).
copilot_main() {
  BB_HOOK="$1"
  # Copilot's shared global plugin is not handed an ingest URL (Claude injects one via
  # managed-settings env); default to prod, overridable via BLUEBEAR_INGEST_URL for a
  # PR/dev-env test. claude_main (Claude) is unaffected — its env is always injected.
  [ -z "$BLUEBEAR_INGEST_URL" ] && BLUEBEAR_INGEST_URL="https://ingest.bluebear.io"
  BB_EVENT=$(cat)
  [ -z "$BB_EVENT" ] && exit 0
  case "$BB_EVENT" in '{'*) ;; *) exit 0 ;; esac

  BB_SID=$(bluebear_field sessionId)

  # Keep the seat on the latest guard despite Copilot's plugin-version pinning. Runs before
  # the handler check (so it happens regardless of handler presence) and is self-throttled.
  [ "$BB_HOOK" = "SessionStart" ] && copilot_self_update

  bluebear_handler_running && exit 0

  BB_CWD=$(bluebear_field cwd)
  bluebear_prompt_id "$BB_HOOK"
  bluebear_session_ctx "$BB_CWD" copilot_gh_login   # shared cache; Copilot login resolver passed by name
  BB_TOOL=$(bluebear_field toolName)

  # Copilot's toolArgs is an escaped JSON STRING. Pull command/file_path BY KEY (not by
  # position — toolArgs is not guaranteed last) and re-emit them as bluebear_json_value-escaped scalars,
  # so tool_input is ALWAYS valid JSON. Never splice the raw string into the body — a
  # malformed toolArgs would otherwise break the whole envelope (fail-open, no enforcement).
  CB_CMD=$(printf '%s' "$BB_EVENT" | sed -n 's/.*\\"command\\"[[:space:]]*:[[:space:]]*\\"\([^\\]*\)\\".*/\1/p' | head -n1)
  CB_FP=$(printf '%s' "$BB_EVENT" | sed -n 's/.*\\"\(file_path\|path\)\\"[[:space:]]*:[[:space:]]*\\"\([^\\]*\)\\".*/\2/p' | head -n1)
  CB_TI=$(printf '{"command":%s,"file_path":%s}' "$(bluebear_json_value "$CB_CMD")" "$(bluebear_json_value "$CB_FP")")

  # Parity with Claude's claude_enriched_body: pass the FULL raw event through (so the prompt,
  # tool response, and any other Copilot field are captured for monitoring/naming — NOT
  # dropped) and append the normalized common fields the parser reads. camelCase originals
  # (toolName/toolArgs/sessionId) coexist with the snake_case common keys — no collisions.
  # bluebear_org is omitted (Copilot has no per-org id); github_login lets the BE resolve it.
  CB_EXTRA=$(printf '"agent_type":"copilot","hook_event_name":"%s","session_id":%s,"tool_name":%s,"tool_input":%s,"developer_email":%s,"github_login":%s,"event_id":"%s","source":"copilot_plugin","git_branch":%s,"git_repo_root":%s,"prompt_id":%s' \
    "$BB_HOOK" "$(bluebear_json_value "$BB_SID")" "$(bluebear_json_value "$BB_TOOL")" "$CB_TI" \
    "$(bluebear_json_value "$BB_DEV")" "$(bluebear_json_value "$BB_LOGIN")" "$(bluebear_uuid)" \
    "$(bluebear_json_value "$BB_GB")" "$(bluebear_json_value "$BB_GR")" "$(bluebear_json_value "$BB_PID")")
  CB_BODY=$(bluebear_merge_event "$CB_EXTRA")

  if [ "$BB_HOOK" = "PreToolUse" ]; then
    BB_RESP=$(bluebear_post "$CB_BODY" 10)
    case "$BB_RESP" in
      *'"decision":"deny"'* | *'"decision": "deny"'*)
        BB_REASON=$(printf '%s' "$BB_RESP" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -z "$BB_REASON" ] && BB_REASON='Blocked by Bluebear policy'
        copilot_emit_deny "$BB_REASON"
        ;;
    esac
    exit 0
  fi

  bluebear_post "$CB_BODY" 8 >/dev/null 2>&1
  exit 0
}
