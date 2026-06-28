#!/bin/bash
# Force-refresh all enabled atvloadly apps via the MCP API, wait for the
# re-sign to actually finish, then send ONE push notification with the result
# (success AND failure). Intended to be driven by atvloadly-refresh.timer.
set -uo pipefail
BASE="http://localhost:5533"
MCP="$BASE/mcp"
LOG="$HOME/atvloadly-refresh.log"
TIMEOUT=300
TS() { date '+%Y-%m-%d %H:%M:%S'; }
enc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }
notify() { curl -s "$BASE/api/notify/send?title=$(enc "$1")&desc=$(enc "$2")" > /dev/null; }
dline() { sed -n 's/^data: //p' | tail -n1; }

# open MCP session
SID=$(curl -s -D - -o /dev/null -X POST "$MCP" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"systemd-refresher","version":"1.0"}}}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2; exit}')
[ -z "$SID" ] && { echo "[$(TS)] ERROR: no MCP session" >> "$LOG"; notify "Atvloadly Refresh" "Failed - could not reach atvloadly ❌"; exit 1; }

mcp() { curl -s -X POST "$MCP" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SID" -d "$1" | dline; }

# enabled app ids
IDS=$(curl -s "$BASE/api/apps" | python3 -c 'import json,sys; print(" ".join(str(a["ID"]) for a in json.load(sys.stdin)["data"] if a.get("enabled")))')
[ -z "$IDS" ] && { echo "[$(TS)] ERROR: no apps" >> "$LOG"; notify "Atvloadly Refresh" "Failed - no enabled apps found ❌"; exit 1; }

# queue refresh per app
for id in $IDS; do
  mcp "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"id\":2,\"params\":{\"name\":\"refresh_app\",\"arguments\":{\"app_id\":$id}}}" >/dev/null
  echo "[$(TS)] queued app_id=$id" >> "$LOG"
done

# poll until nothing in progress (or timeout)
elapsed=0; STATUS=""
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  sleep 5; elapsed=$((elapsed+5))
  STATUS=$(mcp '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"get_refresh_status","arguments":{}}}')
  INPROG=$(printf '%s' "$STATUS" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["structuredContent"]["summary"]["in_progress_count"])
except Exception: print(-1)')
  [ "$INPROG" = "0" ] && break
done

# build report + notify (always: success AND failure)
REPORT=$(printf '%s' "$STATUS" | python3 -c '
import json, sys
sc = json.load(sys.stdin)["result"]["structuredContent"]; s = sc["summary"]
ok = s.get("success_count") or 0
fail = s.get("failed_count") or 0
total = ok + fail
lines = []
for it in sc.get("items", []):
    mark = "OK" if it.get("refresh_state") == "completed_success" else "FAIL(%s)" % it.get("last_error_code")
    lines.append("%s: %s" % (it.get("ipa_name"), mark))
print("Atvloadly Refresh")
if fail == 0:
    print("Success - All apps refreshed successfully ✅")
else:
    print("Failed - %d of %d app(s) failed ❌ | %s" % (fail, total, " | ".join(lines)))
')
TITLE=$(printf '%s\n' "$REPORT" | sed -n '1p')
BODY=$(printf  '%s\n' "$REPORT" | sed -n '2p')
[ -z "$TITLE" ] && { TITLE="Atvloadly Refresh"; BODY="Status unknown - refresh timed out ❌"; }
notify "$TITLE" "$BODY"
echo "[$(TS)] NOTIFIED - $TITLE | $BODY" >> "$LOG"
echo "$TITLE"; echo "$BODY"
