# start_receiver.ps1 - launched by Sunshine when a stream begins
$pythonw = "C:\Users\Shekt\AppData\Local\Programs\Python\Python312\pythonw.exe"
$script  = "C:\mic-routing\mic_receiver.py"
$pidFile = "C:\mic-routing\receiver.pid"

# Kill any stale instance
if (Test-Path $pidFile) {
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

$proc = Start-Process -FilePath $pythonw -ArgumentList "`"$script`"" -WindowStyle Hidden -PassThru
$proc.Id | Out-File $pidFile -Encoding ascii
