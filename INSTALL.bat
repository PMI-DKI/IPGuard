@echo off
setlocal
title IPGuard - Install

rem --- Minta hak Administrator kalau belum ---
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="--elevated" (
        echo Gagal mendapat hak Administrator. Klik kanan INSTALL.bat lalu pilih Run as administrator.
        pause
        exit /b 1
    )
    echo Meminta hak Administrator...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-IPGuard.ps1"
echo.
pause
