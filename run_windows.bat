@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
if defined OPEN_SHELF_PYTHON goto configured_python
py -3 -c "import sys; raise SystemExit(sys.version_info < (3,10))" >nul 2>nul
if not errorlevel 1 goto python_launcher
python -c "import sys; raise SystemExit(sys.version_info < (3,10))" >nul 2>nul
if not errorlevel 1 goto python_command
echo Install Python 3.10 or newer, then open this file again. See docs\setup.md.
set "result=1"
goto finish
:configured_python
"%OPEN_SHELF_PYTHON%" -X utf8 scripts\start_project.py --demo %*
set "result=%errorlevel%"
goto finish
:python_launcher
py -3 -X utf8 scripts\start_project.py --demo %*
set "result=%errorlevel%"
goto finish
:python_command
python -X utf8 scripts\start_project.py --demo %*
set "result=%errorlevel%"
:finish
echo.
pause
exit /b %result%
