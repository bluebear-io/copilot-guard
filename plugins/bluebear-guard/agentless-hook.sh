# Canonical source for the agentless Claude Code hook library (POSIX sh).
#
# Embedded VERBATIM into claude-code.template.json as env.BB_LIB; every hook command is
# `eval "$BB_LIB"; bb_main <HookName>`. A test asserts the template copy equals this file.
#
# Hard constraint: a fresh machine is assumed to have ONLY the hook shell (sh on macOS/Linux,
# Git Bash on Windows), git, and curl. We never assume jq, node, python, or uuidgen exist, and
# we validate every external tool before use. node/jq are used ONLY for the best-effort
# transcript-derived LLMResponse/LLMThinking events, and only when detected.
#
# Behavior mirrors the prior jq hooks (see DEN-2746). POSIX sh only — no bashisms, no `local`.

# --- helpers -------------------------------------------------------------------------------

# RFC4122-v4 UUID without depending on uuidgen: prefer uuidgen, then /proc, then /dev/urandom.
bb_uuid() {
  BB_U=''
  if command -v uuidgen >/dev/null 2>&1; then
    BB_U=$(uuidgen | tr 'A-F' 'a-f')
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    BB_U=$(cat /proc/sys/kernel/random/uuid)
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    BB_U=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' \
      | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-8\4-\5/')
  fi
  # No UUID source available — surface it (fail loud) rather than emit an empty id silently.
  [ -z "$BB_U" ] && echo '[bluebear] bb_uuid: no UUID source (uuidgen/proc/urandom) available' >&2
  printf '%s' "$BB_U"
}

# JSON string escaping for the single-line scalars we inject. Escapes backslash and quote, plus
# tab and CR — a control char in a server deny reason would otherwise produce unparseable deny
# JSON, which Claude Code treats as "no decision" and lets the tool call through (fail-open).
# Every value reaches here single-line (the `[^"]*` field extraction can't cross newlines, and
# JSON encodes any real newline as the two chars \n), so a raw newline never occurs. tab/CR are
# matched as literal bytes, portable across BSD and GNU sed. Backslash is escaped first so the
# escape sequences introduced afterwards are not double-escaped.
bb_esc() {
  BB_TAB=$(printf '\t')
  BB_CR=$(printf '\r')
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$BB_TAB/\\\\t/g" -e "s/$BB_CR/\\\\r/g"
}

# A JSON value: quoted-escaped string, or literal null when empty.
bb_jv() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(bb_esc "$1")"; fi; }

# First top-level "field":"value" string out of the event (best-effort, no JSON parser).
bb_field() {
  printf '%s' "$BB_EVENT" \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# POST a JSON body to the agentless endpoint; echoes the response. No-op (rc 1) without curl.
bb_post() {
  command -v curl >/dev/null 2>&1 || return 1
  printf '%s' "$1" | curl -s --max-time "$2" \
    -X POST "$BLUEBEAR_INGEST_URL/api/v1/events/agentless" \
    -H 'Content-Type: application/json' -d @- 2>/dev/null
}

# Splice our enrichment into the raw event (no parse): drop the closing brace, append fields.
bb_enriched_body() {
  BB_TRIM=$(printf '%s' "$BB_EVENT" | sed -e 's/[[:space:]]*$//')
  BB_OPEN=${BB_TRIM%\}}
  printf '%s,"event_id":"%s","developer_email":%s,"bluebear_org":"%s","source":"managed_hook","bluebear_settings_hash":%s,"prompt_id":%s,"git_branch":%s,"git_repo_root":%s}' \
    "$BB_OPEN" "$(bb_uuid)" "$BB_DEV_JSON" "$(bb_esc "$BLUEBEAR_ORG_ID")" \
    "$BB_HASH_JSON" "$BB_PID_JSON" "$BB_GB_JSON" "$BB_GR_JSON"
}

# True when the local BlueBear handler daemon is up — then the handler owns capture.
bb_handler_running() {
  BB_RT="$HOME/.bluebear/runtime.json"
  [ -r "$BB_RT" ] || return 1
  BB_PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' "$BB_RT" | head -n1)
  [ -n "$BB_PORT" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -sf -m 1 -o /dev/null "http://127.0.0.1:$BB_PORT/status" 2>/dev/null
}

# Developer email: Claude oauth account, else git config.
bb_dev_email() {
  BB_EM=''
  BB_CJ="$HOME/.claude.json"
  [ -r "$BB_CJ" ] && BB_EM=$(sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BB_CJ" | head -n1)
  if [ -z "$BB_EM" ] && command -v git >/dev/null 2>&1; then
    BB_EM=$(git config ${1:+-C "$1"} user.email 2>/dev/null)
  fi
  printf '%s' "$BB_EM"
}

# Prompt-id state (shared by every agent): mint on UserPromptSubmit, cache per session,
# read it back on later hooks so a tool call correlates to its prompt. Sets BB_PID.
# Uses BB_SID (already set by the caller).
bb_prompt_id() {
  BB_SDIR="$HOME/.bluebear-agentless"
  mkdir -p "$BB_SDIR" 2>/dev/null
  # Sanitize session_id before putting it in a path — it comes from the event JSON, so strip
  # anything that isn't a safe filename char to prevent a `/` or `..` escaping the cache dir.
  BB_SID_SAFE=$(printf '%s' "$BB_SID" | tr -dc 'A-Za-z0-9_-')
  BB_PF="$BB_SDIR/${BB_SID_SAFE:-nosession}.prompt"
  if [ "$1" = "UserPromptSubmit" ]; then
    BB_PID=$(bb_uuid)
    [ -n "$BB_SID" ] && printf '%s' "$BB_PID" >"$BB_PF" 2>/dev/null
  else
    BB_PID=$(cat "$BB_PF" 2>/dev/null)
  fi
}

# Git context (shared) from working dir $1. Sets BB_GB (branch), BB_GROOT (repo path),
# BB_GREMOTE (origin url), and BB_GR (repo NAME — the Claude `git_repo_root` value).
bb_git() {
  BB_GB=''; BB_GROOT=''; BB_GREMOTE=''; BB_GR=''
  [ -n "$1" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  BB_GB=$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)
  BB_GROOT=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)
  BB_GREMOTE=$(git -C "$1" remote get-url origin 2>/dev/null)
  BB_GR=$(printf '%s' "$BB_GREMOTE" | sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#.*[/:]##')
}

# Developer's GitHub login — Copilot CLI is GitHub-authenticated, so `gh` is present/authed.
# The BE resolves the org from this login (the shared global plugin carries no org id).
cb_gh_login() {
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
cb_emit_deny() {
  printf '{"permissionDecision":"deny","permissionDecisionReason":"%s"}' "$(bb_esc "$1")"
}

bb_emit_deny() {
  # $1 = reason, $2 = prefix (e.g. "🚫🐻 " or "")
  printf '{"systemMessage":"%s%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
    "$2" "$(bb_esc "$1")" "$(bb_esc "$1")"
}

# Last-turn LLMResponse/LLMThinking — identical to today, best-effort via jq when present.
# Needs a JSON parser, so it is skipped on hosts without jq (core capture is unaffected).
# The all-turns rework that removes jq from this path entirely is tracked in DEN-2751.
bb_capture_llm() {
  command -v jq >/dev/null 2>&1 || return 0
  BB_TP=$(bb_field transcript_path)
  [ -n "$BB_TP" ] || return 0
  [ -f "$BB_TP" ] || return 0
  bb_capture_llm_jq
}

bb_capture_llm_jq() {
  BB_ANS=$(jq -s -r '[.[]|select(.type=="assistant")]|last|(.message.content//[])|map(select(.type=="text")|.text)|join("\n")' "$BB_TP" 2>/dev/null)
  if [ -n "$BB_ANS" ]; then
    BB_MD=$(jq -s -r '[.[]|select(.type=="assistant")]|last|.message.model//empty' "$BB_TP" 2>/dev/null)
    BB_IT=$(jq -s -r '[.[]|select(.type=="assistant")]|last|.message.usage.input_tokens//empty' "$BB_TP" 2>/dev/null)
    BB_CR=$(jq -s -r '[.[]|select(.type=="assistant")]|last|.message.usage.cache_read_input_tokens//empty' "$BB_TP" 2>/dev/null)
    BB_CC=$(jq -s -r '[.[]|select(.type=="assistant")]|last|.message.usage.cache_creation_input_tokens//empty' "$BB_TP" 2>/dev/null)
    printf '%s' "$BB_EVENT" | jq -c \
      --arg dev "$BB_DEV" --arg org "$BLUEBEAR_ORG_ID" --arg eid "$(bb_uuid)" --arg ans "$BB_ANS" \
      --arg md "$BB_MD" --arg gb "$BB_GB" --arg gr "$BB_GR" --arg pid "$BB_PID" \
      --arg it "$BB_IT" --arg cr "$BB_CR" --arg cc "$BB_CC" \
      '. + {hook_event_name:"LLMResponse",llm_response:$ans,event_id:$eid,developer_email:$dev,bluebear_org:$org,source:"managed_hook",prompt_id:(if $pid==""then null else $pid end),model:(if $md==""then null else $md end),input_tokens:($it|tonumber? // null),cache_read_tokens:($cr|tonumber? // null),cache_creation_tokens:($cc|tonumber? // null),git_branch:(if $gb==""then null else $gb end),git_repo_root:(if $gr==""then null else $gr end)}' \
      | { command -v curl >/dev/null 2>&1 && curl -s --max-time 8 -X POST "$BLUEBEAR_INGEST_URL/api/v1/events/agentless" -H 'Content-Type: application/json' -d @- >/dev/null 2>&1; }
  fi
  BB_THK=$(jq -s -r '[.[]|select(.type=="assistant")]|last|(.message.content//[])|map(select(.type=="thinking")|.thinking)|join("\n")' "$BB_TP" 2>/dev/null)
  if [ -n "$BB_THK" ]; then
    printf '%s' "$BB_EVENT" | jq -c \
      --arg dev "$BB_DEV" --arg org "$BLUEBEAR_ORG_ID" --arg eid "$(bb_uuid)" --arg thk "$BB_THK" \
      --arg gb "$BB_GB" --arg gr "$BB_GR" --arg pid "$BB_PID" \
      '. + {hook_event_name:"LLMThinking",llm_thinking:$thk,event_id:$eid,developer_email:$dev,bluebear_org:$org,source:"managed_hook",prompt_id:(if $pid==""then null else $pid end),git_branch:(if $gb==""then null else $gb end),git_repo_root:(if $gr==""then null else $gr end)}' \
      | { command -v curl >/dev/null 2>&1 && curl -s --max-time 8 -X POST "$BLUEBEAR_INGEST_URL/api/v1/events/agentless" -H 'Content-Type: application/json' -d @- >/dev/null 2>&1; }
  fi
}

# --- main dispatcher -----------------------------------------------------------------------

bb_main() {
  BB_HOOK="$1"
  BB_EVENT=$(cat)
  [ -z "$BB_EVENT" ] && exit 0
  case "$BB_EVENT" in '{'*) ;; *) exit 0 ;; esac
  BB_SID=$(bb_field session_id)

  # PreToolUse lock_check: runs first and on every call, even when the handler is up.
  if [ "$BB_HOOK" = "PreToolUse" ]; then
    BB_LR=$(bb_post "{\"bluebear_org\":\"$(bb_esc "$BLUEBEAR_ORG_ID")\",\"session_id\":\"$(bb_esc "$BB_SID")\",\"lock_check\":true}" 6)
    case "$BB_LR" in
      *'"decision":"deny"'* | *'"decision": "deny"'*)
        BB_REASON=$(printf '%s' "$BB_LR" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -z "$BB_REASON" ] && BB_REASON='🐻 BLUEBEAR — session locked'
        bb_emit_deny "$BB_REASON" ''
        exit 0
        ;;
    esac
  fi

  bb_handler_running && exit 0

  BB_DEV=$(bb_dev_email)
  BB_CWD=$(bb_field cwd)
  bb_git "$BB_CWD"
  bb_prompt_id "$BB_HOOK"

  BB_DEV_JSON=$(bb_jv "$BB_DEV")
  BB_HASH_JSON=$(bb_jv "$BLUEBEAR_SETTINGS_HASH")
  BB_PID_JSON=$(bb_jv "$BB_PID")
  BB_GB_JSON=$(bb_jv "$BB_GB")
  BB_GR_JSON=$(bb_jv "$BB_GR")

  if [ "$BB_HOOK" = "Stop" ]; then
    bb_post "$(bb_enriched_body)" 8 >/dev/null 2>&1
    bb_capture_llm
    exit 0
  fi

  if [ "$BB_HOOK" = "PreToolUse" ]; then
    BB_RESP=$(bb_post "$(bb_enriched_body)" 10)
    case "$BB_RESP" in
      *'"decision":"deny"'* | *'"decision": "deny"'*)
        BB_REASON=$(printf '%s' "$BB_RESP" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -z "$BB_REASON" ] && BB_REASON='Blocked by BlueBear policy'
        bb_emit_deny "$BB_REASON" '🚫🐻 '
        ;;
    esac
    exit 0
  fi

  bb_post "$(bb_enriched_body)" 8 >/dev/null 2>&1
  exit 0
}

# --- Copilot dispatcher ---------------------------------------------------------------------
# The Copilot guardrails plugin is ONE global plugin shared across all customers, so it carries
# no org id (unlike Claude's per-org managed-settings). We enrich from the local machine
# (github_login, developer_email, git) into the handler Envelope shape; the ingest endpoint
# resolves the org from github_login. Shares every helper + the prompt_id state with bb_main.
# Copilot input differs: `sessionId`/`toolName`/`toolArgs`(a JSON string)/`cwd`, and Copilot
# expects the flat `{"permissionDecision":"deny"}` shape (cb_emit_deny).
# Shared per-session identity+git cache (AGENT-AGNOSTIC) — avoid re-running the login/git/config
# IO on EVERY tool call. Sets BB_LOGIN, BB_DEV, BB_GB, BB_GR. login + developer_email are stable
# per session (resolved once); git branch/repo re-resolve only when cwd changes. The login SOURCE
# is agent-specific, so the dispatcher passes its resolver fn by name (Copilot: cb_gh_login;
# Codex/etc. pass their own). State lives next to the prompt-id file. $1 = cwd, $2 = login-resolver fn.
bb_ctx() {
  BB_CTX="$BB_SDIR/${BB_SID_SAFE:-nosession}.ctx"
  BB_LOGIN=''; BB_DEV=''; BB_GB=''; BB_GR=''; BB_C_CWD=''
  if [ -r "$BB_CTX" ]; then
    BB_LOGIN=$(sed -n 's/^login=//p' "$BB_CTX" | head -n1)
    BB_DEV=$(sed -n 's/^email=//p' "$BB_CTX" | head -n1)
    BB_C_CWD=$(sed -n 's/^cwd=//p' "$BB_CTX" | head -n1)
    BB_GB=$(sed -n 's/^branch=//p' "$BB_CTX" | head -n1)
    BB_GR=$(sed -n 's/^repo=//p' "$BB_CTX" | head -n1)
  fi
  [ -z "$BB_LOGIN" ] && BB_LOGIN=$("$2")
  [ -z "$BB_DEV" ] && BB_DEV=$(bb_dev_email "$1")
  [ "$BB_C_CWD" != "$1" ] && bb_git "$1"   # bb_git sets BB_GB, BB_GR
  printf 'login=%s\nemail=%s\ncwd=%s\nbranch=%s\nrepo=%s\n' \
    "$BB_LOGIN" "$BB_DEV" "$1" "$BB_GB" "$BB_GR" >"$BB_CTX" 2>/dev/null
}

# Shared enrichment: append caller-provided fields to the RAW hook event, preserving EVERY
# original field (prompt, tool response, etc.) so downstream monitoring/naming is identical
# across agents. $1 = fields WITHOUT the wrapping braces. Used by every agent dispatcher
# (Copilot's cb_main today; Codex/other global-settings agents reuse this same code).
bb_merge_event() {
  BB_TRIM=$(printf '%s' "$BB_EVENT" | sed -e 's/[[:space:]]*$//')
  printf '%s,%s}' "${BB_TRIM%\}}" "$1"
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
cb_self_update() {
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

cb_main() {
  BB_HOOK="$1"
  # Copilot's shared global plugin is not handed an ingest URL (Claude injects one via
  # managed-settings env); default to prod, overridable via BLUEBEAR_INGEST_URL for a
  # PR/dev-env test. bb_main (Claude) is unaffected — its env is always injected.
  [ -z "$BLUEBEAR_INGEST_URL" ] && BLUEBEAR_INGEST_URL="https://ingest.bluebear.io"
  BB_EVENT=$(cat)
  [ -z "$BB_EVENT" ] && exit 0
  case "$BB_EVENT" in '{'*) ;; *) exit 0 ;; esac

  BB_SID=$(bb_field sessionId)

  # Keep the seat on the latest guard despite Copilot's plugin-version pinning. Runs before
  # the handler check (so it happens regardless of handler presence) and is self-throttled.
  [ "$BB_HOOK" = "SessionStart" ] && cb_self_update

  bb_handler_running && exit 0

  BB_CWD=$(bb_field cwd)
  bb_prompt_id "$BB_HOOK"
  bb_ctx "$BB_CWD" cb_gh_login   # shared cache; Copilot login resolver passed by name
  BB_TOOL=$(bb_field toolName)

  # Copilot's toolArgs is an escaped JSON STRING. Pull command/file_path BY KEY (not by
  # position — toolArgs is not guaranteed last) and re-emit them as bb_jv-escaped scalars,
  # so tool_input is ALWAYS valid JSON. Never splice the raw string into the body — a
  # malformed toolArgs would otherwise break the whole envelope (fail-open, no enforcement).
  CB_CMD=$(printf '%s' "$BB_EVENT" | sed -n 's/.*\\"command\\"[[:space:]]*:[[:space:]]*\\"\([^\\]*\)\\".*/\1/p' | head -n1)
  CB_FP=$(printf '%s' "$BB_EVENT" | sed -n 's/.*\\"\(file_path\|path\)\\"[[:space:]]*:[[:space:]]*\\"\([^\\]*\)\\".*/\2/p' | head -n1)
  CB_TI=$(printf '{"command":%s,"file_path":%s}' "$(bb_jv "$CB_CMD")" "$(bb_jv "$CB_FP")")

  # Parity with Claude's bb_enriched_body: pass the FULL raw event through (so the prompt,
  # tool response, and any other Copilot field are captured for monitoring/naming — NOT
  # dropped) and append the normalized common fields the parser reads. camelCase originals
  # (toolName/toolArgs/sessionId) coexist with the snake_case common keys — no collisions.
  # bluebear_org is omitted (Copilot has no per-org id); github_login lets the BE resolve it.
  CB_EXTRA=$(printf '"agent_type":"copilot","hook_event_name":"%s","session_id":%s,"tool_name":%s,"tool_input":%s,"developer_email":%s,"github_login":%s,"event_id":"%s","source":"copilot_plugin","git_branch":%s,"git_repo_root":%s,"prompt_id":%s' \
    "$BB_HOOK" "$(bb_jv "$BB_SID")" "$(bb_jv "$BB_TOOL")" "$CB_TI" \
    "$(bb_jv "$BB_DEV")" "$(bb_jv "$BB_LOGIN")" "$(bb_uuid)" \
    "$(bb_jv "$BB_GB")" "$(bb_jv "$BB_GR")" "$(bb_jv "$BB_PID")")
  CB_BODY=$(bb_merge_event "$CB_EXTRA")

  if [ "$BB_HOOK" = "PreToolUse" ]; then
    BB_RESP=$(bb_post "$CB_BODY" 10)
    case "$BB_RESP" in
      *'"decision":"deny"'* | *'"decision": "deny"'*)
        BB_REASON=$(printf '%s' "$BB_RESP" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -z "$BB_REASON" ] && BB_REASON='Blocked by BlueBear policy'
        cb_emit_deny "$BB_REASON"
        ;;
    esac
    exit 0
  fi

  bb_post "$CB_BODY" 8 >/dev/null 2>&1
  exit 0
}
