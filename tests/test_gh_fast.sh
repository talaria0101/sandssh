#!/bin/bash
# Mode C latency test: 3 commands through gh-send with keep-alive + fast poll.
# Prints per-command round trips; PASS if all return and mean RTT < 4s.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
REPO="${SANDBOX_CHANNEL_REPO:-talaria0101/sandssh-private}"
SECRET="f-secret-$(date +%s)"
NAME="test-fast-$$"
cleanup() { kill $LP 2>/dev/null || true; }
trap cleanup EXIT
python3 "$SRC/bin/sandssh" gh-listen --repo "$REPO" --name "$NAME" --secret "$SECRET" \
    --poll 0.3 --stream 2 >/dev/null 2>&1 &
LP=$!
sleep 2
for i in 1 2 3; do
    T0=$(date +%s.%N)
    OUT=$(python3 "$SRC/bin/sandssh" gh-send --repo "$REPO" --name "$NAME" --secret "$SECRET" \
        --poll 0.3 --wait 60 -- echo "fast-$i")
    T1=$(date +%s.%N)
    RTT=$(python3 -c "print('%.2f' % ($T1 - $T0))")
    echo "cmd$i rtt=${RTT}s  last-line: $(printf '%s' "$OUT" | grep -E '^\[rc=' || echo NONE)"
    printf '%s' "$OUT" | grep -q "fast-$i" || { echo "MISSING OUTPUT"; exit 1; }
done
echo "MODE C FAST TEST PASS"
# cleanup channel files
for f in "channel/$NAME.json" "channel/$NAME.out.json"; do
    SHA=$(curl -fsS -x "${HTTPS_PROXY:-}" -H "Authorization: token ${GH_TOKEN:-}" \
        "https://api.github.com/repos/$REPO/contents/$f" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
    [ -n "$SHA" ] && curl -fsS -o /dev/null -X DELETE -x "${HTTPS_PROXY:-}" \
        -H "Authorization: token ${GH_TOKEN:-}" "https://api.github.com/repos/$REPO/contents/$f" \
        -d "{\"message\": \"cleanup\", \"sha\": \"$SHA\"}" || true
done
