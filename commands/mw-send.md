---
description: Leave a message for another active Claude Code session on this repo (delivered to its context on its next prompt or tool use)
argument-hint: <session-id-prefix | all> <message>
allowed-tools: Bash
---

!`bash "${CLAUDE_PLUGIN_ROOT}/commands/mw-send.sh" $ARGUMENTS`

Report concisely whether the message was queued and to which session(s). If the output shows a usage error or a recipient list, relay the available session ids so the user can pick one. Do not perform any other actions.
