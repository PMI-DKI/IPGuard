@echo off
title IPGuard - Status
echo.
echo === Scheduled Task IPGuard ===
schtasks /Query /TN IPGuard /FO LIST
echo.
echo === 15 baris log terakhir ===
if exist "%ProgramData%\IPGuard\IPGuard.log" (
    powershell -NoProfile -Command "Get-Content '%ProgramData%\IPGuard\IPGuard.log' | Select-Object -Last 15"
) else (
    echo Log belum ada.
)
echo.
pause
