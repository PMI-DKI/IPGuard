@echo off
setlocal
title IPGuard - Uninstall

rem --- Minta hak Administrator kalau belum ---
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="--elevated" (
        echo Gagal mendapat hak Administrator. Klik kanan UNINSTALL.bat lalu pilih Run as administrator.
        pause
        exit /b 1
    )
    echo Meminta hak Administrator...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-IPGuard.ps1"
echo.
pause
