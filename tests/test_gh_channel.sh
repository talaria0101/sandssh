#!/bin/bash
# Mode C e2e: gh-send -> private repo channel files -> gh-listen -> result.
# Needs GH_TOKEN with repo scope on $SANDBOX_CHANNEL_REPO (default
# talaria0101/sandssh-private). Files under channel/ are removed afterwards.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "GH_TOKEN required" >&2; exit 1; }
REPO="${SANDBOX_CHANNEL_REPO:-talaria0101/sandssh-private}"
SECRET="c-secret-$(date +%s)"
NAME="test-e2e-$$"

python3 "$SRC/bin/sandssh" gh-listen --repo "$REPO" --name "$NAME" --secret "$SECRET" --poll 1 &
LP=$!
trap 'kill $LP 2>/dev/null || true' EXIT
sleep 2

OUT=$(python3 "$SRC/bin/sandssh" gh-send --repo "$REPO" --name "$NAME" --secret "$SECRET" \
    --poll 1 --wait 90 -- echo hello-from-modeC '&&' uname -s)
echo "$OUT"
RC=$(printf '%s\n' "$OUT" | grep -c '^\[rc=0 in ' || true)
echo "gh-send rc-lines: $RC"
[ "$RC" -ge 1 ] || { echo "MODE C TEST FAIL" >&2; exit 1; }

# cleanup: remove channel files
for f in "channel/$NAME.json" "channel/$NAME.out.json"; do
    SHA=$(curl -fsS -x "${HTTPS_PROXY:-}" -H "Authorization: token $TOKEN" \
        "https://api.github.com/repos/$REPO/contents/$f" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha',''))" || true)
    [ -n "$SHA" ] && curl -fsS -o /dev/null -X DELETE -x "${HTTPS_PROXY:-}" \
        -H "Authorization: token $TOKEN" \
        "https://api.github.com/repos/$REPO/contents/$f" \
        -d "{\"message\": \"sandssh test cleanup\", \"sha\": \"$SHA\"}" || true
done
echo "MODE C TEST PASS"
