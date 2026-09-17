# start_receiver.ps1 - launched by Sunshine when a stream begins
$pythonw = "C:\Users\Shekt\AppData\Local\Programs\Python\Python312\pythonw.exe"
$script  = "C:\mic-routing\mic_receiver.py"
$pidFile = "C:\mic-routing\receiver.pid"

$log = "C:\mic-routing\receiver.log"
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }

# Switch default recording device to CABLE Output so apps pick up the Deck mic.
# Runs under the SunshineService (LocalSystem) token, so the module must be
# resolvable machine-wide (C:\Program Files\WindowsPowerShell\Modules) — a
# CurrentUser/OneDrive-scoped install is NOT visible here. See receiver.log.
try {
    Import-Module AudioDeviceCmdlets -ErrorAction Stop
    # Look CABLE Output up by name: its ID changes whenever VB-Audio re-enumerates
    # (it did on 2026-09-16 and the hardcoded ID silently stopped matching).
    $cable = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Recording' -and $_.Name -like 'CABLE Output*' } | Select-Object -First 1
    if (-not $cable) { throw "no recording device named 'CABLE Output*'" }
    Set-AudioDevice -Id $cable.ID -ErrorAction Stop | Out-Null
    Log "OK: default recording device set to $($cable.Name)"
} catch {
    Log "FAIL: mic switch -> $($_.Exception.Message)"
}

# Kill any stale instance
if (Test-Path $pidFile) {
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

$proc = Start-Process -FilePath $pythonw -ArgumentList "`"$script`"" -WindowStyle Hidden -PassThru
$proc.Id | Out-File $pidFile -Encoding ascii
