#!/usr/bin/env bash
# Live curl test suite. Usage: scripts/live-test.sh <BASE_URL> <API_KEY>
set -u
BASE="${1:?base url}"; KEY="${2:?api key}"
HERMES_URL="${3:-}"
PASS=0; FAIL=0
t() { # t <name> <expected> <got>
  if [ "$3" = "$2" ]; then echo "  PASS  $1 (got $3)"; PASS=$((PASS+1));
  else echo "  FAIL  $1 (expected $2, got $3)"; FAIL=$((FAIL+1)); fi
}

echo "-- 1. auth wall: POST /v1/chat/completions WITHOUT key --"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/chat/completions" \
  -H 'content-type: application/json' -d '{"messages":[{"role":"user","content":"hi"}]}' 2>&1)
t "401 without key" 401 "$C"

echo "-- 2. basic auth in Authorization header --"
C=$(curl -sS -o /dev/null -w '%{http_code}' -u "user:$KEY" "$BASE/v1/models")
t "200 with basic auth" 200 "$C"

echo "-- 3. dashboard behind auth wall --"
C=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/")
t "401 dashboard without auth" 401 "$C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -u "web:$KEY" "$BASE/")
t "200 dashboard with basic auth" 200 "$C"

echo "-- 4. gateway stats + default model --"
S=$(curl -sS "$BASE/api/stats" -H "Authorization: Bearer $KEY")
DMODEL=$(echo "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin)["default_model"])' 2>/dev/null || echo "")
echo "  stats: $(echo "$S" | head -c 240)…"
[ -n "$DMODEL" ] && t "default model present" 1 1 || { t "default model present" 1 0; DMODEL="anthropic.claude-haiku-4-5-20251001-v1:0"; }
echo "  default model: $DMODEL"

echo "-- 5. chat completion (non-stream, model=$DMODEL) --"
RESP=$(curl -sS -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "{\"model\":\"$DMODEL\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: HELLO FROM BEDROCK\"}]}")
CODE=$(echo "$RESP" | python3 -c 'import json,sys;
try: d=json.load(sys.stdin); print("400" if "error" in d else "200")
except Exception: print("?")')
CONTENT=$(echo "$RESP" | python3 -c 'import json,sys;
try: d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content","") if "error" not in d else json.dumps(d["error"]))
except Exception: print("-")' 2>/dev/null)
t "chat returns 200" 200 "$CODE"
echo "  assistant: $CONTENT"
echo "  raw: $(echo "$RESP" | head -c 400)"

echo "-- 6. streaming SSE --"
CH=$(curl -sN -m 90 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "{\"model\":\"$DMODEL\",\"stream\":true,\"max_tokens\":60,\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 5, digits separated by commas.\"}]}" \
  | grep -c '^data:' || true)
[ "${CH:-0}" -gt 0 ] && t "sse chunks received" 1 1 || t "sse chunks received" 1 0
echo "  chunks: $CH"
curl -sN -m 90 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "{\"model\":\"$DMODEL\",\"stream\":true,\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Say READY in one word\"}]}" \
  | head -6 | sed 's/^/  SSE> /'

echo "-- 7. tool calling (hermes agent compat) --"
TRESP=$(curl -sS -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "{\"model\":\"$DMODEL\",\"max_tokens\":200,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get current weather for a city\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Stockholm? Use the get_weather tool.\"}]}")
TOOLS=$(echo "$TRESP" | python3 -c 'import json,sys;
try:
  d=json.load(sys.stdin); tc=d["choices"][0]["message"].get("tool_calls") or []
  print(",".join(t["function"]["name"] for t in tc))
except Exception: print("?")' 2>/dev/null)
[ "$TOOLS" = "get_weather" ] && t "tool_calls emitted" 1 1 || { t "tool_calls emitted" 1 0; echo "  raw: $(echo "$TRESP" | head -c 400)"; }

echo "-- 8. /v1/models --"
IDS=$(curl -sS "$BASE/v1/models" -H "Authorization: Bearer $KEY" | python3 -c 'import json,sys;d=json.load(sys.stdin)["data"];print(" ".join(m["id"] for m in d[:8]))' 2>/dev/null)
echo "  models: ${IDS:-<none>}"
[ -n "$IDS" ] && t "models list non-empty" 1 1 || t "models list non-empty" 1 0

echo "-- 9. hermes dashboard behind the auth wall --"
if [[ "$HERMES_URL" == https://* ]]; then
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$HERMES_URL")
  t "401 hermes without key" 401 "$C"
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -u "web:$KEY" "$HERMES_URL")
  t "200 hermes with key" 200 "$C"
  T=$(curl -s -m 30 -u "web:$KEY" "$HERMES_URL" | head -c 200)
  echo "  hermes body head: ${T:0:160}"
else
  echo "  (skipped — no hermes URL passed)"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] && echo "ALL LIVE TESTS PASSED" || echo "SOME LIVE TESTS FAILED"
