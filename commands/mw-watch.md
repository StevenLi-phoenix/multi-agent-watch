---
description: Subscribe to another active session — get pinged when it changes its summary or ends. `--list` shows your subscriptions, `--stop <id>` unsubscribes.
argument-hint: <session-id-prefix> | --list | --stop <session-id-prefix>
allowed-tools: Bash
---

!`bash "${CLAUDE_PLUGIN_ROOT}/commands/mw-watch.sh" "$ARGUMENTS"`

Report concisely what happened: which session(s) you subscribed to / unsubscribed from, or the list of sessions you're watching. If the output shows a target list, relay the available session ids so the user can pick one. Subscription notifications arrive later via the normal multi-agent-watch context injection. Do not perform any other actions.
