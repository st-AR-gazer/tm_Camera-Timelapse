@echo off
cd /d "%~dp0"

set SCRIPT_REL=mtlog_viewer_tk.py

pythonw "%~dp0%SCRIPT_REL%" 2>nul || python "%~dp0%SCRIPT_REL%"

exit /b 0
