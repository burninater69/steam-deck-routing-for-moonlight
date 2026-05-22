"""
mic_receiver.py — Steam Deck mic router (Windows side)
Receives raw PCM audio from the Steam Deck over UDP and plays it
into VB-Audio Virtual Cable, making it available as a microphone
to Claude Desktop and any other app.

Requirements:
    pip install pyaudio
    VB-Audio Virtual Cable installed (vb-audio.com/Cable)

Usage:
    python mic_receiver.py
    python mic_receiver.py --port 4444 --rate 44100
    python mic_receiver.py --list-devices
"""

import socket
import pyaudio
import sys
import argparse
import time

DEFAULT_PORT     = 4444
DEFAULT_RATE     = 44100
DEFAULT_CHANNELS = 1
CHUNK            = 2048


def list_devices(p):
    print("\nAvailable output audio devices:")
    print(f"  {'Index':<6} {'Name'}")
    print("  " + "-" * 50)
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if info["maxOutputChannels"] > 0:
            print(f"  {i:<6} {info['name']}")
    print()


def find_vb_cable(p):
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if "CABLE Input" in info["name"] and info["maxOutputChannels"] > 0:
            return i
    return None


def run(port, rate, channels, device_index=None):
    p = pyaudio.PyAudio()

    if device_index is None:
        device_index = find_vb_cable(p)
        if device_index is None:
            print("ERROR: VB-Audio CABLE Input device not found.")
            print("       Install from https://vb-audio.com/Cable and reboot.")
            list_devices(p)
            p.terminate()
            sys.exit(1)

    dev_name = p.get_device_info_by_index(device_index)["name"]
    print(f"[mic_receiver] Output device : {dev_name} (index {device_index})")
    print(f"[mic_receiver] Sample rate   : {rate} Hz")
    print(f"[mic_receiver] Channels      : {channels}")
    print(f"[mic_receiver] UDP port      : {port}")
    print()

    stream = p.open(
        format=pyaudio.paInt16,
        channels=channels,
        rate=rate,
        output=True,
        output_device_index=device_index,
        frames_per_buffer=CHUNK,
    )

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(1.0)

    print(f"[mic_receiver] Listening on UDP 0.0.0.0:{port}")
    print("[mic_receiver] Waiting for Steam Deck audio stream...")
    print("               Press Ctrl-C to stop.\n")

    last_rx = None
    packets  = 0

    try:
        while True:
            try:
                data, addr = sock.recvfrom(CHUNK * 2)
            except socket.timeout:
                if last_rx and time.time() - last_rx > 5:
                    print("[mic_receiver] No data for 5 s — is stream_mic.sh still running?")
                    last_rx = None
                continue

            if last_rx is None:
                print(f"[mic_receiver] Receiving audio from {addr[0]}:{addr[1]}")

            stream.write(data)
            last_rx = time.time()
            packets += 1

            if packets % 500 == 0:
                print(f"[mic_receiver] {packets} packets received — stream healthy")

    except KeyboardInterrupt:
        print(f"\n[mic_receiver] Stopped after {packets} packets.")
    finally:
        stream.stop_stream()
        stream.close()
        p.terminate()
        sock.close()


def main():
    parser = argparse.ArgumentParser(description="Steam Deck mic → VB-Audio Virtual Cable")
    parser.add_argument("--port",         type=int, default=DEFAULT_PORT)
    parser.add_argument("--rate",         type=int, default=DEFAULT_RATE)
    parser.add_argument("--channels",     type=int, default=DEFAULT_CHANNELS)
    parser.add_argument("--device",       type=int, default=None)
    parser.add_argument("--list-devices", action="store_true")
    args = parser.parse_args()

    if args.list_devices:
        p = pyaudio.PyAudio()
        list_devices(p)
        p.terminate()
        sys.exit(0)

    run(args.port, args.rate, args.channels, args.device)


if __name__ == "__main__":
    main()
