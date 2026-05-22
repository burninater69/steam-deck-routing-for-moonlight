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
