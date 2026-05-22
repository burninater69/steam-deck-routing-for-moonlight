# Steam Deck Mic Routing for Moonlight

Routes the Steam Deck's internal microphone to Windows over UDP during Moonlight streaming sessions, making it available as a virtual microphone to any app (e.g. Claude Desktop). Everything starts and stops automatically — no manual steps per session.

## Architecture

```
Steam Deck mic
  → ffmpeg (PulseAudio capture)
  → UDP :4444
  → mic_receiver.py (Windows)
  → VB-Audio CABLE Input
  → CABLE Output (appears as mic input to any app)
```

The Steam Deck side watches for the Moonlight process and starts/stops the stream automatically. The Windows side is triggered by Sunshine's `global_prep_cmd` at session start/end.

## Requirements

### Windows
- [VB-Audio Virtual Cable](https://vb-audio.com/Cable) — provides the virtual mic device
- Python 3.x with `pyaudio`: `pip install pyaudio`
- [Sunshine](https://github.com/LizardByte/Sunshine) as the streaming host

### Steam Deck
- ffmpeg (available in SteamOS by default)
- PulseAudio / PipeWire (default on SteamOS)
- [Moonlight](https://moonlight-stream.org) installed as a Flatpak

---

## Windows Setup

### 1. Place files
Copy the `windows/` folder contents to `C:\mic-routing\`.

### 2. Configure Sunshine global_prep_cmd
In `D:\Sunshine\config\sunshine.conf`, add to `global_prep_cmd` (alongside any existing entries):

```
do: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File C:\mic-routing\start_receiver.ps1
undo: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File C:\mic-routing\stop_receiver.ps1
```

This starts `mic_receiver.py` hidden when a Moonlight session begins and stops it on disconnect.

### 3. Firewall rule (run as Admin)
```powershell
netsh advfirewall firewall add rule name="SteamDeckMicStream" protocol=UDP dir=in localport=4444 action=allow
```

### 4. Set your app's mic input
In your app's audio settings, select **"CABLE Output (VB-Audio Virtual Cable)"** as the microphone.

### Important: default audio output
Do **not** set CABLE Input as the Windows default audio output. Sunshine captures the default output via WASAPI loopback — if CABLE Input is the default, mic audio will echo back to the Deck. Keep your speakers/headphones (e.g. Focusrite) as the default output.

### Optional: Task Scheduler auto-start
Import `MicReceiver_Task.xml` into Task Scheduler to start the receiver at login (useful for testing outside of Sunshine).

---

## Steam Deck Setup

### 1. Place files
```bash
mkdir -p ~/mic-routing
cp steamdeck/stream_mic.sh ~/mic-routing/
cp steamdeck/moonlight_watcher.sh ~/mic-routing/
cp steamdeck/launch_moonlight.sh ~/mic-routing/
chmod +x ~/mic-routing/*.sh
```

### 2. Install the systemd watcher service
```bash
mkdir -p ~/.config/systemd/user
cp steamdeck/mic-moonlight-watcher.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mic-moonlight-watcher.service
```

The watcher polls every 3 seconds for the Moonlight process. When Moonlight starts, it launches `stream_mic.sh`. When Moonlight exits, it kills the stream. No changes to your existing Moonlight shortcut needed.

### 3. Check status
```bash
journalctl --user -u mic-moonlight-watcher.service -n 30
```

---

## How the PC IP is detected

`stream_mic.sh` reads the Windows PC's current IP from Moonlight's own config file:

```
~/.var/app/com.moonlight_stream.Moonlight/config/Moonlight Game Streaming Project/Moonlight.conf
```

Moonlight writes `localaddress=<ip>` there each session, so the stream target updates automatically if the PC's DHCP lease changes. A fallback IP is compiled into the script in case the config isn't found.

---

## Troubleshooting

**No audio in input test (Windows Sound Settings → CABLE Output):**
1. Check `mic_receiver.py` is running: `netstat -an | findstr 4444`
2. SSH to Deck, check ffmpeg is running: `ps aux | grep ffmpeg`
3. Verify Moonlight config has the right IP: `grep localaddress ~/.var/app/com.moonlight_stream.Moonlight/config/Moonlight\ Game\ Streaming\ Project/Moonlight.conf`
4. Check packets are arriving: restart `mic_receiver.py` in a terminal and watch for `Receiving audio from ...`

**Watcher not starting the stream:**
```bash
systemctl --user status mic-moonlight-watcher.service
journalctl --user -u mic-moonlight-watcher.service -n 20
```
The watcher uses `pgrep -x moonlight` — if Moonlight's flatpak ever changes its internal process name, update the watcher script.

**Echo (mic audio heard back on the Deck):**
CABLE Input has become the Windows default audio output. Switch the default back to your speakers/headphones via Sound Settings or:
```powershell
# Using AudioDeviceCmdlets — use -Id, not -Index (indices shift with USB devices)
Set-AudioDevice -Id '{0.0.0.00000000}.{ac33f7b7-4f8c-4059-9c5a-f4cfa0765d63}'
```

---

## File Reference

### Windows (`C:\mic-routing\`)
| File | Purpose |
|------|---------|
| `mic_receiver.py` | Listens on UDP 4444, writes PCM audio to CABLE Input |
| `start_receiver.ps1` | Kills stale instance, starts `mic_receiver.py` hidden, saves PID |
| `stop_receiver.ps1` | Kills receiver by PID file |
| `start_receiver.bat` | Manual double-click launcher |
| `MicReceiver_Task.xml` | Task Scheduler definition for auto-start at login |

### Steam Deck (`~/mic-routing/`)
| File | Purpose |
|------|---------|
| `stream_mic.sh` | ffmpeg: captures internal mic → UDP to Windows PC |
| `moonlight_watcher.sh` | Polls for Moonlight process; starts/stops stream_mic.sh |
| `launch_moonlight.sh` | Legacy wrapper (not needed with watcher service) |
| `mic-moonlight-watcher.service` | systemd user service definition |
