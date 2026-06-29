@echo off
REM build.bat — Build Windows Virtual Camera Driver
REM Requires: Visual Studio Build Tools 2022, Windows SDK 10.0.19041+

set CL=/EHsc /O2 /MT /DNDEBUG
set LINKFLAGS=/DLL /SUBSYSTEM:WINDOWS kernel32.lib mfplat.lib mf.lib shlwapi.lib

cl %CL% VirtualCam.cpp /FeVirtualCam.dll %LINKFLAGS%

if %ERRORLEVEL% EQU 0 (
    echo [VirtualCam] Build successful: VirtualCam.dll
) else (
    echo [VirtualCam] Build FAILED
    exit /b 1
)
