#!/usr/bin/env bash
#
# voxhora-loop-runner.sh <task-name> — run one self-improvement loop
# headless via `claude -p` (2026-07-13). Replaces the in-app scheduled
# tasks, which only ran while the Claude desktop app was open+awake and
# died mid-run when it quit/slept (loop-health audit 2026-07-13: zero
# reports ever delivered). launchd + caffeinate -i survives app state
# and prevents idle-sleep mid-run; missed slots coalesce on wake.
#
# Prompt = the task's SKILL.md body (single source of truth, same files
# the in-app scheduler used): ~/.claude/scheduled-tasks/<task>/SKILL.md
#
# Auth: the CLI's own OAuth (keychain "Claude Code-credentials"). If it
# 401s, the log says so loudly — fix = run `claude login` once.
#
set -uo pipefail

TASK="${1:?usage: voxhora-loop-runner.sh <task-name>}"
SKILL="$HOME/.claude/scheduled-tasks/$TASK/SKILL.md"
LOGDIR="$HOME/Voxhora_Logs/loops"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$LOGDIR/${TASK}_${STAMP}.log"
PROJECT_DIR="$HOME/Documents/Documents - patrick’s MacBook Air/Claude_Projects/Voxhora"
mkdir -p "$LOGDIR"

[ -f "$SKILL" ] || { echo "FATAL: no SKILL.md for $TASK" | tee "$LOG"; exit 1; }

# Strip the YAML frontmatter; the body is the prompt.
PROMPT="$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{print}' "$SKILL")"
[ -n "$PROMPT" ] || PROMPT="$(cat "$SKILL")"

cd "$PROJECT_DIR" || { echo "FATAL: project dir missing" | tee "$LOG"; exit 1; }

{
  echo "=== $TASK run $STAMP (headless claude -p via launchd) ==="
  # caffeinate -i: no idle sleep while the loop runs (the 3am nightly
  # previously died to sleep 20 minutes in).
  # One automatic retry on a transient API drop ("Connection closed
  # mid-response" killed 11 of 46 runs Jul 15-19, including both
  # nightlies on Jul 18+19 and the weekly's debut). A short pause, then
  # the SAME prompt again; a second failure is a real outage and stays
  # a loud exit 1.
  for ATTEMPT in 1 2; do
    caffeinate -i /opt/homebrew/bin/claude -p "$PROMPT" \
      --dangerously-skip-permissions \
      --add-dir "$HOME/voxhora-ios" --add-dir "$HOME/voxhora-mac" \
      --add-dir "$HOME/Obsidian/Voxhora"
    RC=$?
    [ $RC -eq 0 ] && break
    if [ $ATTEMPT -eq 1 ]; then
      echo "--- attempt 1 failed (exit $RC) at $(date '+%Y-%m-%d %H:%M:%S'); retrying in 90s ---"
      sleep 90
    fi
  done
  echo "=== exit $RC at $(date '+%Y-%m-%d %H:%M:%S') ==="
  exit $RC
} >> "$LOG" 2>&1
