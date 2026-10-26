@echo off
rem Re-runs TimeQuest on the last build and writes failing paths to output_files\fail_*.txt
cd /d "%~dp0.."
set QSTA=quartus_sta
where quartus_sta >nul 2>nul || (
  for %%D in (C:\intelFPGA_lite\17.0\quartus\bin64 C:\intelFPGA\17.0\quartus\bin64 C:\altera_lite\17.0\quartus\bin64) do if exist "%%D\quartus_sta.exe" set QSTA=%%D\quartus_sta.exe
)
"%QSTA%" --parallel=1 -t scripts\report_failing_paths.tcl
pause
