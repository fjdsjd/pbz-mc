@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PBZMC\Manage-PBZMC.ps1" -Action Uninstall
pause
endlocal
