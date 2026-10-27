@echo off
chcp 65001 >nul
title XKeen Happ - установка на роутер
echo =====================================================================
echo   XKeen Happ: установка на роутер Keenetic / Netcraze с Entware
echo   Роутер сам скачает установщик. Пароль root Entware по умолчанию:
echo   keenetic (смените его после установки командой passwd).
echo =====================================================================
echo.
set ROUTER_IP=
set /p ROUTER_IP="IP роутера [192.168.1.1]: "
if "%ROUTER_IP%"=="" set ROUTER_IP=192.168.1.1

set PORT=222
powershell -NoProfile -Command "if ((Test-NetConnection %ROUTER_IP% -Port 222 -WarningAction SilentlyContinue).TcpTestSucceeded) { exit 0 } else { exit 1 }" >nul 2>&1
if errorlevel 1 set PORT=22
echo SSH на порту %PORT%
echo.
echo Подписку можно будет вставить в веб-панели после установки.
echo.
ssh -p %PORT% -o StrictHostKeyChecking=accept-new root@%ROUTER_IP% "curl -fsSL https://github.com/@REPO@/releases/latest/download/install.sh -o /opt/tmp/install.sh && sh /opt/tmp/install.sh"
if errorlevel 1 (
    echo.
    echo Не получилось. Проверьте IP, что Entware установлен, и пароль root.
    pause
    exit /b 1
)

echo.
echo =====================================================================
echo   Панель: http://%ROUTER_IP%:8099 - задайте пароль и вставьте подписку
echo =====================================================================
start http://%ROUTER_IP%:8099
pause
