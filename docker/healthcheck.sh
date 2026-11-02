#!/bin/sh
# Container health: GET /health (no key needed there). Healthy when the server answers and
# a model is loaded. While the model downloads or the pack is built - which can take hours
# the first time - the container reports healthy, so it is not marked unhealthy for a start
# that is simply slow.
# the same path the entry point writes (the state folder, because /run is root-owned)
PHASE_FILE=${XDG_STATE_HOME:-/data/state}/maya-phase
phase=$(cat "$PHASE_FILE" 2>/dev/null || echo preparing)
if [ "$phase" != running ]; then
  printf 'preparing (%s)\n' "$phase"
  exit 0
fi

PYBIN=${MAYA_APP:-/data/app}/venv/bin/python3
[ -x "$PYBIN" ] || PYBIN=$(command -v python3 || echo python3)

exec "$PYBIN" -c '
import json, sys, urllib.request
url = "http://127.0.0.1:%s/health" % (sys.argv[1],)
try:
    with urllib.request.urlopen(url, timeout=4) as r:
        data = json.load(r)
        sys.exit(0 if r.status == 200 and data.get("status") == "ok" and not data.get("unloaded") else 1)
except Exception as e:
    print("not healthy: %s" % e, file=sys.stderr)
    sys.exit(1)
' "${PORT:-8080}"
