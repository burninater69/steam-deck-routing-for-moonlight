# stop_receiver.ps1 - launched by Sunshine when a stream ends
$pidFile = "C:\mic-routing\receiver.pid"

if (Test-Path $pidFile) {
    $saved = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($saved) { Stop-Process -Id ([int]$saved) -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
} else {
    Get-WmiObject Win32_Process -Filter "Name='pythonw.exe'" |
        Where-Object { $_.CommandLine -like '*mic_receiver*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Restore default recording device to Focusrite (runs under LocalSystem token —
# module must be machine-wide; see start_receiver.ps1 note)
$log = "C:\mic-routing\receiver.log"
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File $log -Append -Encoding utf8 }
try {
    Import-Module AudioDeviceCmdlets -ErrorAction Stop
    Set-AudioDevice -Id '{0.0.1.00000000}.{bf5bdb82-f342-48ae-afb5-3f4526604bf5}' -ErrorAction Stop | Out-Null
    Log "OK: default recording device restored to Focusrite"
} catch {
    Log "FAIL: mic restore -> $($_.Exception.Message)"
}
