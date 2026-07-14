#!/usr/bin/env python3
"""Regenerate the deployed Copilot guard hooks.json from the split hook sources.

The agentless hook library is authored as split POSIX-sh files under agentless/:
shared.sh (agent-agnostic helpers) + copilot.sh (Copilot functions + dispatcher). Copilot
inlines the WHOLE library into each hook's `bash` field, followed by `copilot_main <Dispatch>`.
This script composes shared.sh + copilot.sh and rewrites every hook's `bash` accordingly,
preserving the existing hook keys and their Copilot dispatch names.

Usage:
  build_hooks.py            regenerate hooks.json from the sources
  build_hooks.py --check    rebuild in memory and fail (exit 1) if the committed hooks.json
                            has drifted from the sources
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

_DIR = Path(__file__).resolve().parent
_AGENTLESS = _DIR / "agentless"
_HOOKS_JSON = _DIR / "hooks.json"

# The dispatch name is the token after the dispatcher call on the last line of the current
# `bash` (`copilot_main <Dispatch>` or the pre-rename `cb_main <Dispatch>`); unchanged names.
_DISPATCH_RE = re.compile(r"(?:copilot_main|cb_main)\s+(\S+)\s*$")


def compose_copilot_lib() -> str:
    shared = (_AGENTLESS / "shared.sh").read_text()
    copilot = (_AGENTLESS / "copilot.sh").read_text()
    return shared + "\n" + copilot


def _dispatch_for(bash: str, hook_key: str) -> str:
    last = [line for line in bash.splitlines() if line.strip()][-1]
    m = _DISPATCH_RE.search(last)
    if not m:
        raise SystemExit(f"cannot find dispatcher call in hook {hook_key!r}: {last!r}")
    return m.group(1)


def build_hooks() -> str:
    doc = json.loads(_HOOKS_JSON.read_text())
    lib = compose_copilot_lib()
    for hook_key, entries in doc["hooks"].items():
        for entry in entries:
            dispatch = _dispatch_for(entry["bash"], hook_key)
            entry["bash"] = f"{lib}copilot_main {dispatch}\n"
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    built = build_hooks()
    if "--check" in sys.argv[1:]:
        current = _HOOKS_JSON.read_text() if _HOOKS_JSON.exists() else ""
        if current != built:
            print(
                f"DRIFT: {_HOOKS_JSON.name} is out of date with the agentless/ sources. "
                f"Run `python3 {Path(__file__).name}` to regenerate.",
                file=sys.stderr,
            )
            return 1
        print(f"OK: {_HOOKS_JSON.name} matches the agentless/ sources.")
        return 0
    _HOOKS_JSON.write_text(built)
    print(f"wrote {_HOOKS_JSON}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
