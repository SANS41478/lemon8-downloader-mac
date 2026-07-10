@echo off
cd /d "%~dp0"

:: ============================================
::  Lemon8 Batch Image Downloader
::  Change PROXY_PORT to your proxy HTTP port
::  NO Node.js required (uses built-in PowerShell)
:: ============================================
set PROXY_PORT=7897
set OUTPUT_DIR=images
set URL_FILE=urls.txt
set URL_EXAMPLE=urls.example.txt

:: ============================================
::  First-run: auto create urls.txt from example
:: ============================================
if not exist "%URL_FILE%" (
    if exist "%URL_EXAMPLE%" (
        echo [INIT] First run detected, creating %URL_FILE% from example...
        copy "%URL_EXAMPLE%" "%URL_FILE%" >nul
        echo [INIT] Please edit %URL_FILE% to add your Lemon8 post links.
        echo [INIT] Also check PROXY_PORT in download.bat (current: %PROXY_PORT%)
        echo.
    )
)

:: Check if urls.txt has any actual links (not just comments/blank)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$urls=@(Get-Content '%URL_FILE%' -Encoding UTF8|Where-Object{$_ -and $_ -notmatch '^#'}|ForEach-Object{$_.Trim()});" ^
  "if($urls.Count -eq 0){Write-Host '[WARN] %URL_FILE% has no links!' -ForegroundColor Yellow;Write-Host '       Add Lemon8 post URLs to %URL_FILE% first.' -ForegroundColor Yellow;exit 1}"

if %ERRORLEVEL% NEQ 0 (
    echo.
    pause
    exit /b
)

:: ============================================

echo.
echo ============================================
echo   Lemon8 Batch Image Downloader
echo   Proxy : 127.0.0.1:%PROXY_PORT%
echo   Output: %OUTPUT_DIR%
echo   URLs  : %URL_FILE%
echo ============================================
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0download.ps1" -UrlFile %URL_FILE% -OutputDir %OUTPUT_DIR% -Proxy http://127.0.0.1:%PROXY_PORT%

echo.
echo --------------------------------------------
echo   Done. Press any key to exit...
pause >nul
