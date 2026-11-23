#!/usr/bin/env python3
"""Add (or with --remove, delete) the Clawd hooks in ~/.claude/settings.json.

Merges with whatever is already there and leaves a .clawd-backup copy.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CMD = '"%s" hook' % os.path.join(HERE, "clawd")
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
          "PermissionRequest", "Stop", "SessionEnd"]
PATH = os.path.expanduser("~/.claude/settings.json")


def is_ours(h):
    return h.get("type") == "command" and h.get("command", "").endswith('/clawd" hook')


def main():
    remove = "--remove" in sys.argv
    data = {}
    if os.path.exists(PATH):
        with open(PATH) as f:
            data = json.load(f)
        shutil.copy(PATH, PATH + ".clawd-backup")
    hooks = data.setdefault("hooks", {})
    for ev in EVENTS:
        entries = [e for e in hooks.get(ev, []) if not any(is_ours(h) for h in e.get("hooks", []))]
        if not remove:
            if ev == "PermissionRequest":
                # Waits for a click on Clawd, so it must run in the foreground.
                hook = {"type": "command", "command": CMD, "timeout": 180}
            else:
                hook = {"type": "command", "command": CMD, "timeout": 5, "async": True}
            entries.append({"hooks": [hook]})
        if entries:
            hooks[ev] = entries
        else:
            hooks.pop(ev, None)
    if not hooks:
        data.pop("hooks", None)
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    with open(PATH, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(("Removed" if remove else "Installed") + " Clawd hooks in " + PATH)


if __name__ == "__main__":
    main()
