@echo off
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -File "%~dp0TeamsMentionMonitor.ps1" -IntervalSeconds 30
pause

