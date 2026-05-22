#!/bin/bash
# launch_moonlight.sh — Moonlight launcher with automatic mic streaming
# Starts stream_mic.sh before Moonlight, stops it when Moonlight exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIC_SCRIPT="$SCRIPT_DIR/stream_mic.sh"
MIC_PID_FILE="$SCRIPT_DIR/stream_mic.pid"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

stop_mic() {
    if [ -f "$MIC_PID_FILE" ]; then
        MIC_PID=$(cat "$MIC_PID_FILE")
        if kill -0 "$MIC_PID" 2>/dev/null; then
            echo -e "${YELLOW}[launch_moonlight] Stopping mic stream (PID $MIC_PID)...${NC}"
            kill "$MIC_PID" 2>/dev/null || true
            wait "$MIC_PID" 2>/dev/null || true
        fi
        rm -f "$MIC_PID_FILE"
    fi
}

# Clean up on exit, interrupt, or termination
trap stop_mic EXIT INT TERM

# Start mic stream in background
echo -e "${GREEN}[launch_moonlight] Starting mic stream...${NC}"
bash "$MIC_SCRIPT" &
MIC_PID=$!
echo "$MIC_PID" > "$MIC_PID_FILE"
echo -e "${GREEN}[launch_moonlight] Mic stream started (PID $MIC_PID)${NC}"

# Short delay to let the mic stream connect before Moonlight starts
sleep 2

# Launch Moonlight (flatpak) and wait for it to exit
echo -e "${GREEN}[launch_moonlight] Launching Moonlight...${NC}"
flatpak run --env=QT_IM_MODULE=none com.moonlight_stream.Moonlight "$@"

echo -e "${YELLOW}[launch_moonlight] Moonlight exited — cleaning up mic stream.${NC}"
# trap EXIT will call stop_mic automatically
