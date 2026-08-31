#!/bin/sh
# Mode dispatch for the one-image-three-modes design (DESIGN.md §5.1).
set -e

mkdir -p /run/eh /var/lib/eh/runs
export EH_TRANSPORT=local
export EH_SOCK="${EH_SOCK:-/run/eh/eh.sock}"

wait_for_socket() {
    i=0
    while [ ! -S "$EH_SOCK" ] && [ "$i" -lt 100 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    [ -S "$EH_SOCK" ]
}

MODE="${1:-server}"
shift || true

case "$MODE" in
    server)
        exec supervisord -n -c /etc/supervisor/supervisord.conf
        ;;
    run)
        python3 /opt/eh/ehd/ehd.py &
        EHD_PID=$!
        trap 'kill $EHD_PID 2>/dev/null' TERM INT
        if ! wait_for_socket; then
            echo "ehd never came up" >&2
            exit 5
        fi
        eh run "$@"
        CODE=$?
        kill "$EHD_PID" 2>/dev/null || true
        exit "$CODE"
        ;;
    doctor)
        python3 /opt/eh/ehd/ehd.py &
        EHD_PID=$!
        trap 'kill $EHD_PID 2>/dev/null' TERM INT
        if ! wait_for_socket; then
            echo "ehd never came up" >&2
            exit 5
        fi
        eh doctor "$@"
        CODE=$?
        kill "$EHD_PID" 2>/dev/null || true
        exit "$CODE"
        ;;
    *)
        echo "usage: entrypoint.sh {server|run|doctor} [args...]" >&2
        exit 2
        ;;
esac
