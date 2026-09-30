@echo off
cd /d "%~dp0\.."
call scripts\assemble-runtime.bat
if errorlevel 1 (
  pause
  exit /b 1
)
echo Local synthetic demo only: http://127.0.0.1:8080
echo Demo login: demo / demo-local-only
java -jar dist\mail-client.jar --spring.profiles.active=demo --server.address=127.0.0.1
pause
