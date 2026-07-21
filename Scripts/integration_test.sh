#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Markdown Card.app"
AGENT="$APP/Contents/MacOS/MarkdownCard"
CLI="$APP/Contents/Helpers/mdcard"
THIRD_PARTY_NOTICES="$APP/Contents/Resources/Renderer/THIRD_PARTY_NOTICES.txt"
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
  MARKDOWN_CARD_DISABLE_SYSTEM_SLEEP_MONITOR=1 \
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

assert_card_tags() {
  local card_id="$1"
  local list_json="$2"
  shift 2

  printf '%s' "$list_json" | /usr/bin/python3 -c '
import json
import sys

card_id = sys.argv[1].lower()
expected = sys.argv[2:]
cards = json.load(sys.stdin)["cards"]
card = next((item for item in cards if item["id"].lower() == card_id), None)
if card is None:
    raise SystemExit(f"Card missing from list JSON: {sys.argv[1]}")
actual = card.get("tags")
if actual != expected:
    raise SystemExit(
        f"Unexpected tags for {sys.argv[1]}: {actual!r}; expected {expected!r}"
    )
' "$card_id" "$@"
}

assert_fold_state() {
  local expected="$1"
  local list_json="$2"
  shift 2

  printf '%s' "$list_json" | /usr/bin/python3 -c '
import json
import sys

expected = sys.argv[1] == "true"
card_ids = {value.lower() for value in sys.argv[2:]}
payload = json.load(sys.stdin)
actual = payload.get("isFolded")
if actual is not expected:
    raise SystemExit(
        f"Unexpected Fold state: {actual!r}; expected {expected!r}"
    )
cards = {card["id"].lower(): card for card in payload["cards"]}
for card_id in card_ids:
    if card_id not in cards or cards[card_id]["isVisible"] is not True:
        raise SystemExit(f"Fold changed persistent visibility for card: {card_id}")
' "$expected" "$@"
}

"$ROOT/Scripts/build_and_run.sh" build
test -s "$THIRD_PARTY_NOTICES"
grep -Fq 'mermaid@11.16.0' "$THIRD_PARTY_NOTICES"
grep -Fq 'KeyboardShortcuts@3.0.1' "$THIRD_PARTY_NOTICES"
start_agent

CARD_ID="$(printf '# Integration Card\n\nInitial body.\n' | run_cli create - \
  --title 'Integration Card' \
  --tag '  Research   Notes  ' \
  --tag 'research notes' \
  --tag 'CS   336')"
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"$CARD_ID"* ]]
assert_card_tags "$CARD_ID" "$LIST_JSON" 'Research Notes' 'CS 336'

run_cli tag "$CARD_ID" '  Reading   Queue  ' | grep -qx "$CARD_ID"
LIST_JSON="$(run_cli list --json)"
assert_card_tags "$CARD_ID" "$LIST_JSON" 'Research Notes' 'CS 336' 'Reading Queue'

printf '# Integration Card\n\nUpdated through stdin.\n' | run_cli update "$CARD_ID" - >/dev/null
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"Integration Card"* ]]
assert_card_tags "$CARD_ID" "$LIST_JSON" 'Research Notes' 'CS 336' 'Reading Queue'

AUTO_ID="$(printf '# Auto Before\n\nBody.\n' | run_cli create -)"
printf '# Auto After\n\nChanged.\n' | run_cli update "$AUTO_ID" - >/dev/null
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"Auto After"* ]]
run_cli theme light | grep -qx 'light'
run_cli theme dark | grep -qx 'dark'
run_cli theme system | grep -qx 'system'

run_cli fold | grep -qx 'ok'
run_cli fold | grep -qx 'ok'
LIST_JSON="$(run_cli list --json)"
assert_fold_state true "$LIST_JSON" "$CARD_ID" "$AUTO_ID"
run_cli unfold | grep -qx 'ok'
run_cli unfold | grep -qx 'ok'
LIST_JSON="$(run_cli list --json)"
assert_fold_state false "$LIST_JSON" "$CARD_ID" "$AUTO_ID"

# Fold is process-local: quitting while folded must not persist sleep mode.
run_cli fold | grep -qx 'ok'
run_cli quit | grep -qx 'ok'
wait "$AGENT_PID"
AGENT_PID=""

start_agent
LIST_JSON="$(run_cli list --json)"
[[ "$LIST_JSON" == *"$CARD_ID"* ]]
assert_card_tags "$CARD_ID" "$LIST_JSON" 'Research Notes' 'CS 336' 'Reading Queue'
assert_fold_state false "$LIST_JSON" "$CARD_ID" "$AUTO_ID"
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

echo "Markdown Card CLI integration: passed"
