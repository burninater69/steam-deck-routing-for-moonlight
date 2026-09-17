# audio_output_guard.ps1 - never let Windows' default PLAYBACK device be the VB-Audio cable.
#
# Why: mic_receiver.py writes the Deck mic into the VB-Audio cable, and Sunshine streams
# whatever plays on the default output (WASAPI loopback). If the cable becomes the default
# output, PC audio leaks into the dictation mic and your voice echoes back to the Deck.
# Windows falls back to the cable whenever the Focusrite disappears, which happens every
# time the USB-C switcher hands it to the laptop (2026-09-17 outage).
#
# What it does, every $IntervalSec:
#   - default (either role) is a VB-Audio device -> switch to Focusrite, else Realtek Digital
#     Output, else any other real output. Logged.
#   - if WE put a fallback in place and the Focusrite comes back while that fallback is still
#     the default -> switch back to the Focusrite. If you picked something else by hand in the
#     meantime, your choice is left alone.
# It only ever reacts to VB-Audio being the default; it does not fight other device changes
# (e.g. Sunshine selecting Steam Streaming Speakers).
#
# While a stream is active (C:\mic-routing\receiver.pid exists) it also:
#   - keeps the default MIC on CABLE Output (Windows moves it to the Focusrite on reconnect)
#   - restarts mic_receiver.py if it has died (checked every ~10 s)
#
# Run: scheduled task "AudioOutputGuard" (at logon, hidden, via C:\Claude\run-hidden.vbs).
#      start_receiver.ps1 also calls it with -Once at stream start.
param(
    [switch]$Once,
    [int]$IntervalSec = 2
)

$FocusriteId = '{0.0.0.00000000}.{ac33f7b7-4f8c-4059-9c5a-f4cfa0765d63}'
$Forbidden   = 'VB-Audio'
# Never pick these as a fallback: virtual sinks, Bluetooth hands-free, SteelSeries Sonar.
$NotAFallback = 'VB-Audio|Steam Streaming|Sonar|Hands-Free|NVIDIA Virtual'
$log       = 'C:\mic-routing\audio_output_guard.log'
$stateFile = 'C:\mic-routing\audio_output_guard.fallback'   # ID of the fallback we set, if any

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }

Import-Module AudioDeviceCmdlets -ErrorAction Stop

function Set-Output($dev, $why) {
    Set-AudioDevice -Id $dev.ID -ErrorAction Stop | Out-Null   # sets both default + communications
    Log "SET: $($dev.Name)  ($why)"
}

function Check {
    $playback = @(Get-AudioDevice -List | Where-Object Type -eq 'Playback')
    $def  = $playback | Where-Object Default
    $comm = $playback | Where-Object DefaultCommunication
    $focusrite = $playback | Where-Object ID -eq $FocusriteId

    if (($def -and $def.Name -match $Forbidden) -or ($comm -and $comm.Name -match $Forbidden)) {
        $target = $focusrite
        if (-not $target) { $target = $playback | Where-Object Name -like 'Realtek Digital Output*' | Select-Object -First 1 }
        if (-not $target) { $target = $playback | Where-Object { $_.Name -notmatch $NotAFallback } | Select-Object -First 1 }
        if (-not $target) {
            Log "WARN: default is '$($def.Name)' but there is no non-virtual output to switch to"
            return
        }
        Set-Output $target "default was '$($def.Name)' / comms '$($comm.Name)'"
        if ($target.ID -eq $FocusriteId) { Remove-Item $stateFile -ErrorAction SilentlyContinue }
        else { Set-Content $stateFile $target.ID }
        return
    }

    if (Test-Path $stateFile) {
        $fallbackId = Get-Content $stateFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $def -or $def.ID -ne $fallbackId) {
            Remove-Item $stateFile -ErrorAction SilentlyContinue   # user chose something else; hands off
        } elseif ($focusrite) {
            Set-Output $focusrite "Focusrite is back; replacing the fallback '$($def.Name)'"
            Remove-Item $stateFile -ErrorAction SilentlyContinue
        }
    }
}

if ($Once) {
    try { Check } catch { Log "ERR (once): $($_.Exception.Message)" }
    exit 0
}

# Single instance
$mutex = New-Object System.Threading.Mutex($false, 'Global\AudioOutputGuard')
if (-not $mutex.WaitOne(0)) { exit 0 }

# Receiver watchdog. receiver.pid exists only while a stream is active (start_receiver.ps1
# writes it, stop_receiver.ps1 deletes it). If it exists but no mic_receiver.py process is
# running, the receiver died mid-stream (2026-09-17: killed as hung by Windows) - restart it.
$pidFile = 'C:\mic-routing\receiver.pid'
$script:lastRestart = [datetime]::MinValue
function Check-Receiver {
    if (-not (Test-Path $pidFile)) { return }
    $alive = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
        Where-Object { $_.CommandLine -like '*mic_receiver.py*' }
    if ($alive) { return }
    if (((Get-Date) - $script:lastRestart).TotalSeconds -lt 30) { return }   # no restart storms
    $script:lastRestart = Get-Date
    Log "RECEIVER: stream active but mic_receiver.py is not running - restarting it"
    & 'C:\mic-routing\start_receiver.ps1'
}

# While a stream is active, the default MIC must be CABLE Output (the Deck mic). Windows
# re-points it at the Focusrite whenever that reconnects (USB-C switcher, 2026-09-17 08:51),
# and start_receiver.ps1 only sets it once at stream start. Outside a stream: hands off.
function Check-StreamMic {
    if (-not (Test-Path $pidFile)) { return }
    $rec   = @(Get-AudioDevice -List | Where-Object Type -eq 'Recording')
    $cable = $rec | Where-Object Name -like 'CABLE Output*' | Select-Object -First 1
    if (-not $cable) { return }
    $def  = $rec | Where-Object Default
    $comm = $rec | Where-Object DefaultCommunication
    if ($def.ID -eq $cable.ID -and $comm.ID -eq $cable.ID) { return }
    if (-not (Test-Path $pidFile)) { return }   # stream ended while we looked; stop_receiver owns the mic now
    Set-AudioDevice -Id $cable.ID -ErrorAction Stop | Out-Null
    Log "MIC: stream active, default mic was '$($def.Name)' / comms '$($comm.Name)' - set back to $($cable.Name)"
}

Log "START: guard running (pid $PID, every ${IntervalSec}s)"
$lastErr = ''
$tick = 0
while ($true) {
    try { Check; Check-StreamMic; if (($tick++ % 5) -eq 0) { Check-Receiver }; $lastErr = '' }   # receiver every ~10 s
    catch {
        # Don't spam the log with the same error every 2 s
        if ($_.Exception.Message -ne $lastErr) { Log "ERR: $($_.Exception.Message)"; $lastErr = $_.Exception.Message }
    }
    Start-Sleep -Seconds $IntervalSec
}
