@echo off
setlocal
cd /d "%~dp0\.."
if exist dist\mail-client.jar exit /b 0
for %%N in (001 002 003 004) do if not exist dist\mail-client.jar.part%%N (
  echo Missing runtime part %%N. Extract all four runtime ZIPs into this same project folder.
  exit /b 1
)
if not exist dist\runtime.sha256 exit /b 1
copy /b "dist\mail-client.jar.part001"+"dist\mail-client.jar.part002"+"dist\mail-client.jar.part003"+"dist\mail-client.jar.part004" "dist\mail-client.jar.assembling" >nul
if errorlevel 1 exit /b 1
set "MAIL_RUNTIME_TARGET=%CD%\dist\mail-client.jar.assembling"
for /f "usebackq tokens=1" %%H in ("dist\runtime.sha256") do set "MAIL_RUNTIME_EXPECTED=%%H"
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; if ((Get-FileHash -LiteralPath $env:MAIL_RUNTIME_TARGET -Algorithm SHA256).Hash -ne $env:MAIL_RUNTIME_EXPECTED) { exit 1 }"
if errorlevel 1 (
  echo Runtime checksum mismatch. Do not run it. Download the parts again.
  exit /b 1
)
move /y "dist\mail-client.jar.assembling" "dist\mail-client.jar" >nul
echo Runtime assembled and SHA-256 verified.
exit /b 0
