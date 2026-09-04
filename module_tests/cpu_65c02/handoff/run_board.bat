@echo off
setlocal EnableExtensions
rem ============================================================================
rem run_board.bat - offline runner for the cpu_65c02 handoff kanban board.
rem Not tied to any agent session: runner tasks run straight here; thinking
rem tasks are spawned as detached `pi -p` console windows (one per task).
rem
rem Usage:
rem   run_board.bat                 - usage + current task table
rem   run_board.bat list            - task table + board refresh
rem   run_board.bat refresh         - regenerate BOARD.md only
rem   run_board.bat runners         - run runner tasks (sequential, logged to
rem                                   handoff\logs\<id>.log). Default: only
rem                                   tasks with status=ready; a runner runs
rem                                   only when its gate script exists.
rem   run_board.bat runners --force - also run runners not status=ready
rem   run_board.bat thinking        - spawn pi workers for all READY A*
rem                                   thinking tasks (each in its own window)
rem   run_board.bat thinking A1t    - spawn specific task ids (C tasks only
rem                                   if B3 set them status=ready)
rem   run_board.bat thinking --dry-run
rem                                   - print what would spawn, spawn nothing
rem   run_board.bat all             - runners, then ready thinking tasks
rem
rem Notes:
rem   * pi-free: `list`, `refresh`, `runners` need ONLY the MSYS2 python3
rem     (C:\msys64\ucrt64\bin). No pi, no session, no network agent.
rem     `thinking`/`all` need the pi CLI; `all` runs the runners first and
rem     skips thinking with a notice when pi is absent.
rem   * Thinking workers are ephemeral (pi --no-session); the task file's
rem     progress log + status fields are the record.
rem   * Workers never commit and never run Quartus (in their brief).
rem   * Board state: handoff\BOARD.md (regenerated automatically after runs).
rem ============================================================================
cd /d "%~dp0.."
if not exist "C:\msys64\ucrt64\bin\python3.exe" (
  echo [run_board] ERROR: C:\msys64\ucrt64\bin\python3.exe not found.
  exit /b 1
)
set "PATH=C:\msys64\ucrt64\bin;%PATH%"

if "%~1"=="" goto :usage

set "MODE=%~1"
set "ARGS="
shift
:collect
if "%~1"=="" goto :dispatch
set "ARGS=%ARGS% %~1"
shift
goto :collect

:dispatch
if /i "%MODE%"=="refresh"  goto :do
if /i "%MODE%"=="list"     goto :do
if /i "%MODE%"=="runners"  goto :do
if /i "%MODE%"=="thinking" goto :do
if /i "%MODE%"=="all"      goto :do
:usage
echo.
echo Usage: run_board.bat [list^|refresh^|runners^|thinking^|all] [task ids] [--force^|--dry-run] [-- extra pi args]
echo See the header of handoff\run_board.bat for details.
echo.
python3 handoff\board_query.py list
exit /b 0

:do
python3 handoff\board_query.py %MODE% %ARGS%
exit /b %ERRORLEVEL%
