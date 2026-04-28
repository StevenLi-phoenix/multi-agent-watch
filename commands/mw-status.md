---
description: Show multi-agent-watch registry — active Claude Code sessions across all repos with collision warnings
allowed-tools: Bash
---

!`bash "${CLAUDE_PLUGIN_ROOT}/commands/mw-status.sh"`

Summarize the output above for the user. Group by repo. Highlight any repos showing `!! COLLISION` (multiple concurrent Claude Code sessions). If everything is clean (one session per repo) say so concisely. Do not perform any other actions.
