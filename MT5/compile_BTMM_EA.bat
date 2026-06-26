@echo off
setlocal EnableExtensions

set "METAEDITOR=C:\Program Files\MetaTrader 5 IC Markets Global\metaeditor64.exe"
set "MQL5_ROOT=%APPDATA%\MetaQuotes\Terminal\010E047102812FC0C18890992854220E\MQL5"
set "PROJECT_DIR=%~dp0"
set "PROJECT_MQ5=%PROJECT_DIR%BTMM_EA.mq5"
set "PROJECT_EX5=%PROJECT_DIR%BTMM_EA.ex5"
set "TERMINAL_MQ5=%MQL5_ROOT%\Experts\BTMM_EA.mq5"
set "TERMINAL_EX5=%MQL5_ROOT%\Experts\BTMM_EA.ex5"
set "LOG=%PROJECT_DIR%BTMM_EA_compile.log"

if not exist "%METAEDITOR%" (
  echo ERROR: MetaEditor not found:
  echo   %METAEDITOR%
  pause
  exit /b 1
)

if not exist "%PROJECT_MQ5%" (
  echo ERROR: Source not found:
  echo   %PROJECT_MQ5%
  pause
  exit /b 1
)

echo Copying source into MT5 Experts folder...
copy /Y "%PROJECT_MQ5%" "%TERMINAL_MQ5%" >nul

echo Compiling in MT5 data folder...
"%METAEDITOR%" /compile:"%TERMINAL_MQ5%" /log:"%LOG%" /inc:"%MQL5_ROOT%"

if not exist "%TERMINAL_EX5%" (
  echo.
  echo COMPILE FAILED - no EX5 in MT5 folder.
  echo Check MetaEditor Errors tab or log:
  echo   %LOG%
  if exist "%LOG%" type "%LOG%"
  pause
  exit /b 1
)

echo Copying EX5 to project folder...
copy /Y "%TERMINAL_EX5%" "%PROJECT_EX5%" >nul

if exist "%PROJECT_EX5%" (
  echo.
  echo SUCCESS
  echo   %PROJECT_EX5%
  exit /b 0
)

echo ERROR: EX5 compiled but copy to project folder failed.
pause
exit /b 1
