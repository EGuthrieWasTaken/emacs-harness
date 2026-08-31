#!/bin/sh
# Runs under supervisord in `server` mode, after ehd is already up: brings
# up one default session so there is always something to look at, then
# stays alive as x11vnc + websockify for the browser view (DESIGN.md §10).
set -e

export EH_TRANSPORT=local
EH_SOCK="${EH_SOCK:-/run/eh/eh.sock}"

i=0
while [ ! -S "$EH_SOCK" ] && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
done

DEFAULT_PROFILE="${EH_DEFAULT_PROFILE:-smoke}"
DEFAULT_GEOMETRY="${EH_GEOMETRY:-1280x800}"

eh session new --name default --profile "$DEFAULT_PROFILE" --geometry "$DEFAULT_GEOMETRY" \
    >/var/log/eh/bootstrap-session.log 2>&1 || true

DISPLAY_NUM=$(eh session list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    matches = [s["display"] for s in d.get("sessions", []) if s["name"] == "default"]
    print(matches[0] if matches else "")
except Exception:
    print("")
')

if [ -z "$DISPLAY_NUM" ]; then
    echo "bootstrap: no default session display; browser view unavailable" >&2
    exec tail -f /dev/null
fi

x11vnc -display ":$DISPLAY_NUM" -forever -shared -nopw -localhost -rfbport 5900 \
    -o /var/log/eh/x11vnc.log &
exec websockify --web /usr/share/novnc 6080 localhost:5900
