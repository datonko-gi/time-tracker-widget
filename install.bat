@echo off
setlocal
set "HERE=%~dp0"
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WorkTracker.lnk"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = New-Object -ComObject WScript.Shell; $l = $s.CreateShortcut($env:LNK); $l.TargetPath = $env:HERE + 'WorkTracker.vbs'; $l.WorkingDirectory = $env:HERE; $l.Save()"
if not exist "%LNK%" echo Could not create the Startup shortcut.& exit /b 1
start "" wscript.exe "%HERE%WorkTracker.vbs"
echo WorkTracker installed (autostart + launched).
