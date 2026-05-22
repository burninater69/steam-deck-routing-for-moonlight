#!/bin/bash
# stream_mic.sh — Steam Deck mic router
# Streams mic audio to Windows PC running mic_receiver.py

set -euo pipefail

MOONLIGHT_CONF="/home/deck/.var/app/com.moonlight_stream.Moonlight/config/Moonlight Game Streaming Project/Moonlight.conf"
FALLBACK_IP="192.168.68.246"

# Read PC IP from Moonlight's config — updated by Moonlight each session
DETECTED_IP=""
if [ -f "$MOONLIGHT_CONF" ]; then
    DETECTED_IP=$(grep -m1 'localaddress=' "$MOONLIGHT_CONF" | cut -d= -f2 | tr -d '[:space:]')
fi

WINDOWS_IP="${1:-${DETECTED_IP:-$FALLBACK_IP}}"
PORT="${2:-4444}"
RATE=44100
CHANNELS=1
CHUNK_DURATION=0.05   # 50ms packets

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${GREEN}[stream_mic] Target  : ${WINDOWS_IP}:${PORT}${NC}"
if [ -n "$DETECTED_IP" ] && [ "$DETECTED_IP" = "$WINDOWS_IP" ]; then
    echo -e "${GREEN}[stream_mic] IP source: Moonlight config${NC}"
elif [ -z "$DETECTED_IP" ]; then
    echo -e "${YELLOW}[stream_mic] IP source: fallback (Moonlight config not found)${NC}"
fi
echo -e "${GREEN}[stream_mic] Rate    : ${RATE} Hz  Channels: ${CHANNELS}${NC}"

if ! ping -c 1 -W 2 "$WINDOWS_IP" &>/dev/null; then
    echo -e "${YELLOW}[stream_mic] WARNING: Cannot ping ${WINDOWS_IP}.${NC}"
    echo -e "${YELLOW}             Ensure mic_receiver.py is running on the Windows PC.${NC}"
fi

echo -e "${GREEN}[stream_mic] Detecting microphone...${NC}"

MIC=$(pactl get-default-source 2>/dev/null || true)

if echo "$MIC" | grep -qi "monitor" || [ -z "$MIC" ]; then
    echo -e "${YELLOW}[stream_mic] Default is a monitor or unset — searching for real mic...${NC}"
    MIC=$(pactl list sources short 2>/dev/null         | grep -v "monitor"         | grep -iE "input|mic|headset|usb|analog"         | head -1         | awk '{print $2}')
fi

if [ -z "$MIC" ]; then
    echo -e "${YELLOW}[stream_mic] Available sources:${NC}"
    pactl list sources short
    echo -e "${YELLOW}[stream_mic] Enter source name to use:${NC}"
    read -r MIC
fi

echo -e "${GREEN}[stream_mic] Microphone : ${MIC}${NC}"
echo -e "${GREEN}[stream_mic] Streaming — Press Ctrl-C to stop.${NC}"
echo ""

exec ffmpeg     -f pulse     -i "$MIC"     -ar "$RATE"     -ac "$CHANNELS"     -acodec pcm_s16le     -f s16le     -flush_packets 1     "udp://${WINDOWS_IP}:${PORT}"     -loglevel warning
