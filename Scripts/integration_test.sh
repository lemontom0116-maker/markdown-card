#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Easy Card.app"
AGENT="$APP/Contents/MacOS/EasyCard"
CLI="$APP/Contents/Helpers/mdcard"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/markdown-card-integration.XXXXXX")"
SOCKET="$RUN_ROOT/agent.sock"
STORE="$RUN_ROOT/cards.store"
SUITE="com.garden100.MarkdownCard.integration.$$"
LOG="$RUN_ROOT/agent.log"
AGENT_PID=""

cleanup() {
  if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" >/dev/null 2>&1; then
    kill "$AGENT_PID" >/dev/null 2>&1 || true
    wait "$AGENT_PID" >/dev/null 2>&1 || true
  fi
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

start_agent() {
  MDCARD_SOCKET_PATH="$SOCKET" \
  MARKDOWN_CARD_STORE_URL="$STORE" \
  MARKDOWN_CARD_DEFAULTS_SUITE="$SUITE" \
  "$AGENT" >>"$LOG" 2>&1 &
  AGENT_PID=$!

  for _ in $(seq 1 80); do
    if [ -S "$SOCKET" ]; then
      return
    fi
    if ! kill -0 "$AGENT_PID" >/dev/null 2>&1; then
      echo "Agent exited before opening its IPC socket." >&2
      sed -n '1,160p' "$LOG" >&2
      exit 1
    fi
    sleep 0.05
  done

  echo "Agent did not open its IPC socket within four seconds." >&2
  sed -n '1,160p' "$LOG" >&2
  exit 1
}

run_cli() {
  MDCARD_SOCKET_PATH="$SOCKET" "$CLI" "$@"
}

"$ROOT/Scripts/build_and_run.sh" build
start_agent

CARD_ID="$(printf '# Integration Card\n\nInitial body.\n' | run_cli create - --title 'Integration Card')"
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"$CARD_ID"* ]]

printf '# Integration Card\n\nUpdated through stdin.\n' | run_cli update "$CARD_ID" - >/dev/null
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"Integration Card"* ]]

AUTO_ID="$(printf '# Auto Before\n\nBody.\n' | run_cli create -)"
printf '# Auto After\n\nChanged.\n' | run_cli update "$AUTO_ID" - >/dev/null
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"Auto After"* ]]
run_cli theme light | grep -qx 'light'
run_cli theme dark | grep -qx 'dark'
run_cli theme system | grep -qx 'system'

run_cli quit | grep -qx 'ok'
wait "$AGENT_PID"
AGENT_PID=""

start_agent
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"$CARD_ID"* ]]
run_cli hide "$CARD_ID" | grep -qx 'ok'
run_cli show "$CARD_ID" | grep -qx "$CARD_ID"
run_cli hide "$CARD_ID" | grep -qx 'ok'
run_cli delete "$CARD_ID" | grep -qx 'ok'

DELETED_IDS=""
for index in $(seq 1 10); do
  DELETED_ID="$(printf '# Visible Delete %s\n\nUnsaved-looking content.\n' "$index" | run_cli create -)"
  run_cli delete "$DELETED_ID" --force | grep -qx 'ok'
  DELETED_IDS="$DELETED_IDS $DELETED_ID"
done

run_cli quit | grep -qx 'ok'
wait "$AGENT_PID"
AGENT_PID=""

start_agent
FINAL_LIST="$(run_cli list --json)"
for deleted_id in $DELETED_IDS; do
  if printf '%s' "$FINAL_LIST" | grep -q "$deleted_id"; then
    echo "Deleted visible card was recreated after restart: $deleted_id" >&2
    exit 1
  fi
done
run_cli quit | grep -qx 'ok'
wait "$AGENT_PID"
AGENT_PID=""

echo "Easy Card CLI integration: passed"
