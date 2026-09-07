@echo off
:: NTPulse - Precision Time Synchronization Engine
:: Double-click this file to launch the application.
:: It will request Administrator privileges automatically.

title NTPulse
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0timesync.ps1"
