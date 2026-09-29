#!/usr/bin/env bash
# bufferbloat.sh — measure bufferbloat: how much your ping degrades under load.
#
# The problem it exposes: a link can look "idle" while FIFO buffers in network
# devices quietly add hundreds of ms of latency the moment the channel saturates.
# The fix is active queue management (CoDel / fq_codel), not a "gaming" router
# with RGB.
#
# Method (similar to waveform/flent tests):
#   1. Measure the baseline ping at rest.
#   2. Generate load (iperf3, or parallel curl downloads as a fallback).
#   3. Ping under load -> delta = bufferbloat.
#   4. Grade A..F and advice.
#
# Usage:
#   ./bufferbloat.sh                       # quick test (curl load, ~25 s)
#   ./bufferbloat.sh --host 1.1.1.1        # ping target
#   ./bufferbloat.sh --iperf host.example  # full test via iperf3
#
# Exit codes: 0 — fine (A/B/C), 1 — problems (D..F), 2 — not enough data.
# Handy for cron/monitoring.

set -euo pipefail

PROG="$(basename "$0")"
PING_HOST="1.1.1.1"
IPERF_HOST=""
BASE_N=12          # pings at rest
LOAD_N=15          # pings under load
LOAD_SECONDS=12    # load duration
CURL_WORKERS=6     # parallel downloads when iperf3 is unavailable
CURL_URL="https://speed.cloudflare.com/__down?bytes=50000000"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | tail -n +2; exit "${1:-0}"; }
die()   { echo "Error: $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "utility not found: $1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host)  PING_HOST="$2"; shift 2 ;;
        --iperf) IPERF_HOST="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

need ping
if [ -n "$IPERF_HOST" ] && ! command -v iperf3 >/dev/null 2>&1; then
    die "--iperf given but iperf3 is not installed"
fi

# --- ping: collect times in ms ------------------------------------------------
ping_times() { # $1 count -> ping output on stdout (single run, interval fallback)
    local out
    out="$(ping -c "$1" -i 0.3 "$PING_HOST" 2>/dev/null)" || \
        out="$(ping -c "$1" "$PING_HOST" 2>/dev/null)" || \
        die "host $PING_HOST does not answer ping"
    printf '%s\n' "$out"
}

parse_ms() { # stdin: ping output -> just the time= numbers (ms), one per line
    awk -F'time[= ]+' '/time=/ { split($2, a, " "); print a[1] }'
}

stats() { # stdin: numbers (ms), one per line -> "min avg max p95"
    awk 'NF == 0 { next }
    {
        v[++n] = $1; s += $1
        if (n == 1 || $1 < mn) mn = $1
        if (n == 1 || $1 > mx) mx = $1
    }
    END {
        if (n == 0) { print "— — — —"; exit }
        for (i = 2; i <= n; i++) {          # insertion sort (BSD awk has no asort)
            x = v[i]; j = i - 1
            while (j >= 1 && v[j] > x) { v[j+1] = v[j]; j-- }
            v[j+1] = x
        }
        idx = int(n * 0.95 + 0.999); if (idx < 1) idx = 1; if (idx > n) idx = n
        printf "%.1f %.1f %.1f %.1f", mn, s/n, mx, v[idx]
    }'
}

grade() { # $1 = avg delta (ms) -> letter + text
    awk -v d="$1" 'BEGIN {
        if      (d < 5)   print "A — excellent, queues are under control"
        else if (d < 30)  print "B — good"
        else if (d < 60)  print "C — tolerable, bufferbloat is noticeable"
        else if (d < 200) print "D — bad, queues are clearly overflowing"
        else if (d < 400) print "E — very bad"
        else              print "F — catastrophic: the link is nearly useless under load"
    }'
}

# --- load ---------------------------------------------------------------------
start_iperf_load() {
    iperf3 -c "$IPERF_HOST" -P 4 -t "$LOAD_SECONDS" >/dev/null 2>&1 &
    IPERF_PID=$!
}

start_curl_load() {
    local i
    CURL_PIDS=""
    for ((i = 0; i < CURL_WORKERS; i++)); do
        curl -s --max-time "$((LOAD_SECONDS + 5))" -o /dev/null "$CURL_URL" &
        CURL_PIDS="$CURL_PIDS $!"
    done
}

cleanup() {
    if [ -n "${IPERF_PID:-}" ]; then kill "$IPERF_PID" 2>/dev/null || true; fi
    for p in ${CURL_PIDS:-}; do kill "$p" 2>/dev/null || true; done
    return 0
}
trap cleanup EXIT

main() {
    echo "Bufferbloat probe: ping target = $PING_HOST"
    if [ -n "$IPERF_HOST" ]; then
        echo "Load: iperf3 -> $IPERF_HOST"
    else
        echo "Load: ${CURL_WORKERS} parallel curl downloads (iperf3 not specified)"
    fi

    echo; echo "[1/3] Baseline ping at rest (${BASE_N} packets)..."
    base="$(ping_times "$BASE_N" | parse_ms)"
    [ -n "$(printf '%s' "$base" | tr -d '[:space:]')" ] || die "could not collect a single ping"
    read -r bmin bavg bmax bp95 <<<"$(printf '%s\n' "$base" | stats)"
    echo "  min=${bmin} avg=${bavg} max=${bmax} p95=${bp95} ms"

    echo; echo "[2/3] Load ${LOAD_SECONDS}s + ping under load (${LOAD_N} packets)..."
    if [ -n "$IPERF_HOST" ]; then
        start_iperf_load
    else
        start_curl_load
    fi
    load="$(ping_times "$LOAD_N" | parse_ms)"
    read -r lmin lavg lmax lp95 <<<"$(printf '%s\n' "$load" | stats)"
    echo "  min=${lmin} avg=${lavg} max=${lmax} p95=${lp95} ms"

    echo; echo "[3/3] Verdict"
    if [ "$bavg" != "—" ] && [ "$lavg" != "—" ]; then
        local delta p95d rc
        delta="$(awk -v a="$bavg" -v b="$lavg" 'BEGIN{printf "%.1f", b-a}')"
        p95d="$(awk -v a="$bp95" -v b="$lp95" 'BEGIN{printf "%.1f", b-a}')"
        echo "  delta avg : +${delta} ms  (avg under load - avg at rest)"
        echo "  delta p95 : +${p95d} ms"
        echo "  grade     : $(grade "$delta")"
        echo
        cat <<'EOF'
What to do if the grade is C or worse:
  1. Enable AQM on your router: sqm/fq_codel (OpenWrt: luci-app-sqm).
  2. Check buffer sizes on switches/modem (bufferbloat = huge FIFO queues).
  3. Shape the link slightly below its capacity (95%) so queues grow in your
     AQM instead of at your ISP.
EOF
        rc="$(awk -v d="$delta" 'BEGIN { print ((d+0) >= 60) ? 1 : 0 }')"
        return "$rc"
    else
        echo "  not enough data to compare"
        return 2
    fi
}

main
