#!/bin/bash
# moonlight_watcher.sh — runs as a systemd user service
# Watches for Moonlight process; starts stream_mic.sh when running, stops it when not.

MIC_SCRIPT="/home/deck/mic-routing/stream_mic.sh"
MIC_PID_FILE="/home/deck/mic-routing/stream_mic.pid"
POLL=3

log() { echo "[mic-watcher] $*"; }

mic_running() {
    [ -f "$MIC_PID_FILE" ] && kill -0 "$(cat "$MIC_PID_FILE")" 2>/dev/null
}

start_mic() {
    log "Moonlight detected — starting mic stream..."
    bash "$MIC_SCRIPT" &
    echo $! > "$MIC_PID_FILE"
    log "Mic stream started (PID $(cat "$MIC_PID_FILE"))"
}

stop_mic() {
    local pid
    pid=$(cat "$MIC_PID_FILE" 2>/dev/null)
    log "Moonlight gone — stopping mic stream (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    rm -f "$MIC_PID_FILE"
    log "Mic stream stopped."
}

log "Watcher started. Polling every ${POLL}s for Moonlight..."

while true; do
    if pgrep -x moonlight > /dev/null 2>&1; then
        if ! mic_running; then
            start_mic
        fi
    else
        if mic_running; then
            stop_mic
        fi
    fi
    sleep "$POLL"
done
