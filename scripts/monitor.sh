#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != snapshot && ! "$1" =~ ^[0-9]+$ ) ]]; then
    echo 'Usage: scripts/monitor.sh [interval-seconds|snapshot]' >&2
    exit 2
fi
dir="$HOME/Library/Logs/BetterWispr"
mkdir -p "$dir"
pid() { pgrep -x BetterWispr | head -1; }

snapshot() {
    local p stamp out
    p="$(pid)" || { echo 'BetterWispr is not running' >&2; return 1; }
    stamp="$(date +%Y%m%d-%H%M%S)"
    out="$dir/snapshot-$stamp"
    mkdir -p "$out"
    sample "$p" 3 -file "$out/sample.txt" >/dev/null 2>&1 || true
    footprint "$p" > "$out/footprint.txt" 2>&1 || true
    /usr/bin/log show --last 15m --style compact --predicate 'subsystem == "org.betterwispr.app"' > "$out/app.log" 2>&1 || true
    echo "$out"
}

if [[ "${1:-}" == snapshot ]]; then
    snapshot
    exit
fi

interval="${1:-30}"
csv="$dir/health.csv"
[[ -f "$csv" ]] || echo 'time,pid,cpu_percent,footprint_mb,threads,ports,idle_wakeups' > "$csv"
trap 'kill 0' EXIT

/usr/bin/log stream --style compact --predicate 'subsystem == "org.betterwispr.app"' | while read -r line; do
    echo "$line" >> "$dir/events.log"
    case "$line" in
        *"Main thread behind capture"*|*"digital silence"*|*"Dictation failed"*) snapshot >> "$dir/events.log" & ;;
    esac
done &

echo "Writing $csv and $dir/events.log every ${interval}s. Press Control-C to stop."
while true; do
    if p="$(pid)"; then
        stats="$(top -l 2 -s 1 -pid "$p" -stats cpu,threads,ports,idlew | tail -1 | awk '{for (i = 1; i <= 4; i++) sub(/[^0-9.].*/, "", $i); print $1","$2","$3","$4}')"
        footprint="$(footprint "$p" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/p' | head -1 |
            awk '{print ($2 == "GB" ? $1 * 1024 : $2 == "KB" ? $1 / 1024 : $1)}')"
        echo "$(date +%FT%T),$p,${stats%%,*},${footprint:-},${stats#*,}" >> "$csv"
    fi
    sleep "$interval"
done
