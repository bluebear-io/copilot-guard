"""Hook-registration contract for the Copilot guard plugin.

Copilot only invokes a plugin hook when its top-level key in `hooks.json` EXACTLY
matches a Copilot hook event name. A mismatch means the hook silently never fires
(no error) — the failure mode behind DEN-2947: the prompt/stop hooks were keyed
`userPromptSubmit`/`stop`, but Copilot's events are `userPromptSubmitted`/`agentStop`,
so Copilot sessions produced zero Prompt events and were filtered out of the console
(the dashboard hides zero-prompt sessions). preToolUse/postToolUse/sessionStart/
sessionEnd matched, so those fired — which is exactly why only tool events showed up.

These are Copilot's canonical hook event names, verified against real Copilot CLI
session transcripts (`~/.copilot/session-state/<id>/events.jsonl`, `hook.start.hookType`).
"""
import json
from pathlib import Path

VALID_COPILOT_HOOK_EVENTS = frozenset(
    {
        "preToolUse",
        "postToolUse",
        "userPromptSubmitted",
        "sessionStart",
        "sessionEnd",
        "agentStop",
    }
)

# The prompt hook names a session and keeps it out of the zero-prompt filter; without
# it, governed Copilot sessions vanish from the console and are uncounted.
REQUIRED_HOOK_EVENTS = frozenset({"userPromptSubmitted", "preToolUse", "agentStop"})

HOOKS_JSON = Path(__file__).resolve().parents[1] / "plugins" / "bluebear-guard" / "hooks.json"


def _registered_keys() -> set:
    return set(json.loads(HOOKS_JSON.read_text())["hooks"].keys())


def test_all_hook_keys_are_real_copilot_events() -> None:
    invalid = _registered_keys() - VALID_COPILOT_HOOK_EVENTS
    assert not invalid, (
        f"hooks.json registers keys Copilot never fires (hook silently never runs): "
        f"{sorted(invalid)}. Valid events: {sorted(VALID_COPILOT_HOOK_EVENTS)}"
    )


def test_prompt_and_stop_hooks_are_registered() -> None:
    missing = REQUIRED_HOOK_EVENTS - _registered_keys()
    assert not missing, (
        f"required Copilot hooks not registered: {sorted(missing)} — "
        f"missing the prompt hook means zero-prompt Copilot sessions hidden from the console"
    )


if __name__ == "__main__":
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            _fn()
            print(f"PASS {_name}")
    print("all contract checks passed")
