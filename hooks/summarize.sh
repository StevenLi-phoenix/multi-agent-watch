#!/usr/bin/env bash
# DEPRECATED no-op (0.3.0). Self-summaries are now generated on read by
# /mw-status (lib/registry.sh: mw_refresh_summaries), not on Stop. hooks.json no
# longer wires this file; it stays only so sessions started under a <=0.2.2
# hooks.json (which isn't hot-reloaded) don't log a missing-file error on every
# Stop. Safe to delete once no such session is left running.
exit 0
