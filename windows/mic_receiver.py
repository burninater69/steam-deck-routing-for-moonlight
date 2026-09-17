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

Under pythonw (how Sunshine starts it) there is no console, so output goes to
C:\\mic-routing\\mic_receiver.log.
"""

import ctypes
import ctypes.wintypes
import os
import socket
import pyaudio
import sys
import argparse
import time

DEFAULT_PORT     = 4444
DEFAULT_RATE     = 44100
DEFAULT_CHANNELS = 1
CHUNK            = 2048
LOG_PATH         = r"C:\mic-routing\mic_receiver.log"
LOG_MAX_BYTES    = 1_000_000


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}", flush=True)


def redirect_output_if_windowless():
    # pythonw has no stdout/stderr: without this, a crash leaves no trace at all.
    if sys.stdout is not None:
        return
    if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
        os.replace(LOG_PATH, LOG_PATH + ".old")
    f = open(LOG_PATH, "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = f


_user32 = ctypes.windll.user32
_msg = ctypes.wintypes.MSG()


def pump_messages():
    """Dispatch pending window messages for this thread.

    PortAudio's init leaves a hidden COM window (OleMainThreadWndClass) on the
    main thread. If nobody pumps it, device-change notifications sent to it go
    unanswered and Windows kills the process as hung (AppHang 1002). That is how
    the receiver died at 2026-09-17 08:06, two minutes after an iPhone Bluetooth
    hands-free device connected.
    """
    while _user32.PeekMessageW(ctypes.byref(_msg), None, 0, 0, 1):  # PM_REMOVE
        _user32.TranslateMessage(ctypes.byref(_msg))
        _user32.DispatchMessageW(ctypes.byref(_msg))


def list_devices(p):
    print("\nAvailable output audio devices:")
    print(f"  {'Index':<6} {'Name'}")
    print("  " + "-" * 50)
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if info["maxOutputChannels"] > 0:
            print(f"  {i:<6} {info['name']}")
    print()


def find_vb_cable(p, rate, channels):
    """Return the index of a VB-Audio Virtual Cable render endpoint that opens.

    Don't trust the name alone: after the driver re-enumerated (2026-09-16) the
    cable input came back as "Speakers (2- VB-Audio Virtual Cable)", while the
    endpoint that still matched "CABLE In..." ("CABLE In 16 Ch") refuses to
    open on every host API. So try each candidate and keep the first that works.
    """
    candidates = []
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        name = info["name"]
        if info["maxOutputChannels"] < channels or "VB-Audio" not in name or "Point" in name:
            continue
        # Classic name first, then the renamed endpoint, then anything else on the cable
        rank = 0 if "CABLE Input" in name else 1 if name.startswith("Speakers") else 2
        candidates.append((rank, i))
    for _, i in sorted(candidates):
        try:
            s = p.open(format=pyaudio.paInt16, channels=channels, rate=rate,
                       output=True, output_device_index=i, frames_per_buffer=CHUNK)
            s.close()
            return i
        except OSError:
            continue
    return None


def open_output(port_audio, rate, channels, device_index):
    """Open the cable output stream, retrying until a usable device appears."""
    while True:
        idx = device_index if device_index is not None else find_vb_cable(port_audio, rate, channels)
        if idx is not None:
            try:
                stream = port_audio.open(format=pyaudio.paInt16, channels=channels, rate=rate,
                                         output=True, output_device_index=idx, frames_per_buffer=CHUNK)
                name = port_audio.get_device_info_by_index(idx)["name"]
                log(f"Output device : {name} (index {idx}), {rate} Hz, {channels} ch")
                return stream
            except OSError as e:
                log(f"Could not open device {idx}: {e}")
        else:
            log("No usable VB-Audio cable output found; retrying in 5 s")
        for _ in range(50):  # 5 s, still pumping messages
            pump_messages()
            time.sleep(0.1)


def run(port, rate, channels, device_index=None):
    p = pyaudio.PyAudio()
    stream = open_output(p, rate, channels, device_index)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(0.25)  # short, so messages get pumped even when no audio arrives

    log(f"Listening on UDP 0.0.0.0:{port} (pid {os.getpid()})")

    last_rx = None
    packets  = 0

    try:
        while True:
            pump_messages()
            try:
                data, addr = sock.recvfrom(CHUNK * 2)
            except socket.timeout:
                if last_rx and time.time() - last_rx > 5:
                    log("No data for 5 s — is stream_mic.sh still running?")
                    last_rx = None
                continue

            if last_rx is None:
                log(f"Receiving audio from {addr[0]}:{addr[1]}")

            try:
                stream.write(data)
            except OSError as e:
                # Device vanished or re-enumerated: reopen instead of dying.
                log(f"Write failed ({e}); reopening output device")
                try:
                    stream.close()
                except Exception:
                    pass
                p.terminate()
                p = pyaudio.PyAudio()
                stream = open_output(p, rate, channels, device_index)
                continue

            last_rx = time.time()
            packets += 1

            if packets % 5000 == 0:
                log(f"{packets} packets received — stream healthy")

    except KeyboardInterrupt:
        log(f"Stopped after {packets} packets.")
    finally:
        try:
            stream.stop_stream()
            stream.close()
        except Exception:
            pass
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

    redirect_output_if_windowless()
    try:
        run(args.port, args.rate, args.channels, args.device)
    except Exception:
        import traceback
        log("FATAL:\n" + traceback.format_exc())
        raise


if __name__ == "__main__":
    main()
