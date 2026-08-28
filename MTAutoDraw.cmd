@echo off
REM MTAutoDraw - double-clickable launcher for the GUI.
REM
REM Finds PowerShell 7 and opens MTAutoDrawGui.ps1. -STA is already pwsh's default on Windows and is
REM passed for clarity; WinForms requires it. If pwsh is missing the window would otherwise flash and
REM close with nothing said, so that case is reported and the console is held open.

where pwsh >nul 2>nul
if errorlevel 1 goto :nopwsh

pwsh -NoProfile -STA -File "%~dp0MTAutoDrawGui.ps1"
if errorlevel 1 goto :failed
exit /b 0

:nopwsh
echo.
echo MTAutoDraw needs PowerShell 7, which was not found on your PATH.
echo.
echo Install it from https://aka.ms/powershell and run this file again.
echo Windows PowerShell 5.1 is not enough: the parser uses ForEach-Object -Parallel.
echo.
pause
exit /b 1

:failed
echo.
echo The MTAutoDraw window exited with an error. The message above is from PowerShell.
echo.
pause
exit /b 1
