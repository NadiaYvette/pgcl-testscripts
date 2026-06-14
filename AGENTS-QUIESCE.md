# Background-agent cooperative quiesce
Flag file: /home/nyc/src/pgcl/.agents-quiesce
- `touch /home/nyc/src/pgcl/.agents-quiesce`  → running quiesce-aware agents flush
  their findings to their resume doc and exit at their NEXT checkpoint (between
  steps / before a build). Cooperative, not instant — a mid-build agent winds down
  when that build returns (up to a few min). Then it's safe to reboot.
- `rm /home/nyc/src/pgcl/.agents-quiesce` → clears it; re-spawn agents to resume.
- Hard fallback: TaskStop an agent (abrupt; loses in-context analysis; on-disk work survives).
Agents predating this convention (e.g. the running source-audit agent) don't poll it.
