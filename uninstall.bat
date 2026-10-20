@echo off
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WorkTracker.lnk" 2>nul
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*worktracker.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo WorkTracker stopped and removed from autostart. Data kept in %APPDATA%\WorkTracker.
