#!/usr/bin/env python3
"""Adds Ezra to the Claude desktop app's settings file.

Run it while Claude is quit: Claude writes its settings back when it quits, which removes anything added while it
was open. The entry (the helper's path and the token) is taken from Claude Code's own settings, where
`claude mcp add ... ezra` put it. Nothing secret is printed.
"""
import json, os, shutil, subprocess, sys, time

desktop = os.path.expanduser("~/Library/Application Support/Claude/claude_desktop_config.json")
code = os.path.expanduser("~/.claude.json")

# `ps`, not `pgrep`: pgrep leaves out the processes this script was started from, so run from Claude's own terminal
# it would not see Claude.
processes = subprocess.run(["ps", "-axo", "comm"], capture_output=True, text=True).stdout.splitlines()
if any(line.strip().endswith("/Claude.app/Contents/MacOS/Claude") for line in processes):
    sys.exit("Claude is still open. Quit it first (Cmd-Q), then run this again. Nothing was changed.")

try:
    entry = json.load(open(code))["mcpServers"]["ezra"]
except (OSError, KeyError, ValueError):
    sys.exit("Ezra is not set up in Claude Code yet, so there is no entry to copy. Nothing was changed.")
entry = {"command": entry.get("command", ""), "env": entry.get("env", {})}
if not os.access(entry["command"], os.X_OK) or not entry["env"].get("EZRA_MCP_TOKEN"):
    sys.exit("The Ezra entry in Claude Code is incomplete. Set it up again from Ezra, Settings, Claude. Nothing was changed.")

config = json.load(open(desktop)) if os.path.exists(desktop) else {}
if os.path.exists(desktop):
    shutil.copy2(desktop, desktop + ".before-ezra-" + time.strftime("%Y%m%d-%H%M%S"))
config.setdefault("mcpServers", {})["ezra"] = entry
with open(desktop + ".tmp", "w") as out:
    json.dump(config, out, indent=2)
    out.write("\n")
os.replace(desktop + ".tmp", desktop)
print("Ezra was added to the Claude desktop app's settings. Open Claude now.")
