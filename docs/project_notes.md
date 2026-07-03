# Steam Deck Mic Routing to Claude Desktop

## Purpose
Stream the Steam Deck's internal microphone to the Windows PC over UDP, making it available as a virtual microphone to Claude Desktop during Moonlight streaming sessions. Everything starts and stops automatically — no manual steps per session.

## Architecture
```
Steam Deck mic
  → ffmpeg (PulseAudio capture)
  → UDP :4444
  → mic_receiver.py (Windows)
  → VB-Audio CABLE Input
  → CABLE Output (appears as mic input to Claude Desktop)
```
Claude Desktop mic input: **"CABLE Output (VB-Audio Virtual Cable)"**

## Key facts
- **Moonlight** runs on the Steam Deck (client); **Sunshine** runs on the Windows PC (server)
- Sunshine is installed at `D:\Sunshine\`; live config at `D:\Sunshine\config\`
- Sunshine service: `SunshineService` (restart via taskbar tray icon or elevated `Restart-Service SunshineService`)
- Python: `C:\Users\Shekt\AppData\Local\Programs\Python\Python312\pythonw.exe`
- AudioDeviceCmdlets PowerShell module installed **machine-wide (AllUsers scope: `C:\Program Files\WindowsPowerShell\Modules\AudioDeviceCmdlets`)** — use for reliable audio device switching. **MUST be machine-wide, not CurrentUser.** `SunshineService` runs as **LocalSystem** and launches `start_receiver.ps1` under that token, which cannot see a CurrentUser/OneDrive-scoped module — `Import-Module` fails and the device switch silently no-ops (receiver still launches, but the mic input is never selected).
- **Default Windows audio output: Focusrite USB Audio** (`{0.0.0.00000000}.{ac33f7b7-4f8c-4059-9c5a-f4cfa0765d63}`)
- CABLE Input must NOT be the Windows default audio output — Sunshine captures the default via WASAPI loopback, which would echo mic audio back to the Deck

## Windows files (`C:\mic-routing\`)
| File | Purpose |
|------|---------|
| `mic_receiver.py` | Listens on UDP 4444, writes PCM audio to CABLE Input by explicit device index |
| `start_receiver.ps1` | Sets default recording device to CABLE Output, kills stale instance, starts `pythonw mic_receiver.py` hidden, saves PID to `receiver.pid`. Logs OK/FAIL of the device switch to `receiver.log` |
| `stop_receiver.ps1` | Kills receiver by PID file (fallback WMI scan), restores default recording device to Focusrite. Logs to `receiver.log` |
| `receiver.log` | Timestamped OK/FAIL log of each device switch — first place to check if the mic input isn't auto-selected |
| `start_receiver.bat` / `stop_receiver.bat` | Manual double-click launcher |
| `MicReceiver_Task.xml` | Optional Task Scheduler auto-start at login |

## Sunshine automation (`D:\Sunshine\config\sunshine.conf`)
`global_prep_cmd` has three entries (in order):
1. `mute-audio.ps1 -Mute 1` / `mute-audio.ps1 -Mute 0` — existing Sunshine audio mute (elevated: false)
2. `""` / `restore-displays.ps1` — existing display restore (elevated: true)
3. `start_receiver.ps1` / `stop_receiver.ps1` — **our entry** starts/stops mic_receiver.py (elevated: false)

Sunshine runs prep-cmd in the user session context. **No `audio_sink` setting** — Sunshine captures from the Windows default output (Focusrite). Do NOT add `audio_sink = Steam Streaming Speakers`; it breaks PC→Deck audio because nothing plays to that virtual device.

## Steam Deck files (`/home/deck/mic-routing/`)
| File | Purpose |
|------|---------|
| `stream_mic.sh` | ffmpeg captures internal mic → UDP to `192.168.68.152:4444` |
| `launch_moonlight.sh` | Wrapper: starts stream_mic.sh in bg, launches Moonlight flatpak, kills stream on exit |
| `moonlight_watcher.sh` | Polls every 3s for `moonlight` process; starts/stops stream_mic.sh automatically |

## Steam Deck systemd service (preferred — works with existing Gaming Mode shortcut)
```
~/.config/systemd/user/mic-moonlight-watcher.service
```
- Enabled and auto-starts at login: `systemctl --user enable mic-moonlight-watcher`
- Watches for `pgrep -x moonlight` → starts `stream_mic.sh` when Moonlight is running
- No changes to the existing Moonlight Gaming Mode shortcut needed
- Check status: `journalctl --user -u mic-moonlight-watcher.service -n 20`
- **Fragile**: uses exact process name match (`-x moonlight`). If Moonlight flatpak updates and renames its internal process, watcher breaks silently. Verify with `pgrep -a moonlight` if mic stops auto-starting.

## Moonlight on Steam Deck
- Installed as Flatpak: `com.moonlight_stream.Moonlight` (v6.1.0)
- Process name inside flatpak sandbox: `moonlight`
- Target Windows IP: **dynamically read from Moonlight's config** at stream_mic.sh startup (2026-05-22). Moonlight writes `localaddress=<ip>` to its config each session, so this updates automatically when DHCP changes. Fallback IP `192.168.68.246` used if config not found.
- Config path: `/home/deck/.var/app/com.moonlight_stream.Moonlight/config/Moonlight Game Streaming Project/Moonlight.conf` → key `localaddress=`

## Audio device IDs (Windows)
| Device | ID |
|--------|-----|
| Focusrite USB Audio (default output) | `{0.0.0.00000000}.{ac33f7b7-4f8c-4059-9c5a-f4cfa0765d63}` |
| Steam Streaming Speakers | `{0.0.0.00000000}.{64d0dcad-7719-454e-bbe3-b1a29799a826}` |
| Steam Streaming Microphone | `{0.0.0.00000000}.{6830aafb-69b5-4f69-a08b-5660b8aa6619}` |
| CABLE Input (VB-Audio Virtual Cable) | `{0.0.0.00000000}.{74cee145-4ecd-45ec-b990-d36657bbb08b}` |

## Echo troubleshooting (resolved)
- **Cause**: CABLE Input was the Windows default audio output. Sunshine's WASAPI loopback captured it, streaming mic audio back to the Deck.
- **Fix**: Set Focusrite as the default output via AudioDeviceCmdlets. CABLE Input is only written to by explicit device index in mic_receiver.py, never as the default, so Sunshine never captures it.
- **Note**: Use `-Id '{0.0.0.00000000}.{ac33f7b7-4f8c-4059-9c5a-f4cfa0765d63}'` rather than `-Index 2` — device indices shift when USB devices connect/disconnect.
- Do NOT add `audio_sink` to sunshine.conf — it breaks PC→Deck game audio.

## Mic input not auto-selected (resolved 2026-07-03)
- **Symptom**: after starting a Moonlight stream, mic audio routed fine but the Windows default recording device was NOT switched to CABLE Output — the app kept using the previous mic. The receiver process was running, so the script clearly ran.
- **Cause**: AudioDeviceCmdlets was installed **CurrentUser scope inside OneDrive-redirected Documents** (`C:\Users\Shekt\OneDrive\Documents\WindowsPowerShell\Modules\`), the only copy on disk. `SunshineService` runs as **LocalSystem** and launches `start_receiver.ps1` under that token, whose `PSModulePath` does not include the per-user OneDrive path → `Import-Module AudioDeviceCmdlets` failed → `Set-AudioDevice` unrecognized. Both lines used `-ErrorAction SilentlyContinue`, so the failure was invisible. `Start-Process $pythonw` uses an absolute path and needs no module, so the receiver still launched — hence "routing works, input device not selected."
- **Fix**: (1) install AudioDeviceCmdlets **machine-wide** (`C:\Program Files\WindowsPowerShell\Modules`), which LocalSystem's default `PSModulePath` always includes; (2) `start_receiver.ps1` / `stop_receiver.ps1` now use `-ErrorAction Stop` and log OK/FAIL to `C:\mic-routing\receiver.log` instead of swallowing errors.
- **Diagnose next time**: check `C:\mic-routing\receiver.log` for a `FAIL:` line at stream start.

## Desktop shortcuts (Steam Deck)
- `StreamMicToPC.desktop` — manual stream_mic.sh launcher (legacy, not needed with watcher)
- `MoonlightWithMic.desktop` — wrapper launcher (legacy, not needed with watcher)
- Both in `/home/deck/Desktop/` and `~/.local/share/applications/`

## Firewall (Windows — requires Admin PowerShell)
```powershell
netsh advfirewall firewall add rule name="SteamDeckMicStream" protocol=UDP dir=in localport=4444 action=allow description="Steam Deck mic audio stream"
```
Rule confirmed present and enabled.

## VB-Audio Virtual Cable
- Installed and working (confirmed via `mic_receiver.py --list-devices`)
- Multiple CABLE devices appear due to multiple audio sessions; mic_receiver.py picks the first "CABLE Input" by name scan
- **Fragile**: if VB-Audio adds a second CABLE pair, the wrong device could be selected silently. Verify with `python mic_receiver.py --list-devices` to confirm index in use.
