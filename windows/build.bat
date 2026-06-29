@echo off
REM build.bat — Build Windows Virtual Camera Driver
REM Requires: Visual Studio Build Tools 2022, Windows 10 SDK 10.0.19041+
REM Run from Developer Command Prompt for VS 2022

echo [VirtualCam] Building...

set CL=/EHsc /O2 /MT /DNDEBUG /DUNICODE /D_UNICODE
set LINKFLAGS=/DLL /SUBSYSTEM:WINDOWS kernel32.lib mfplat.lib mfreadwrite.lib mf.lib shlwapi.lib

cl %CL% VirtualCam.cpp /FeVirtualCam.dll %LINKFLAGS%

if %ERRORLEVEL% EQU 0 (
    echo [VirtualCam] Build successful: VirtualCam.dll
    echo.
    echo To install:  regsvr32 VirtualCam.dll
    echo To uninstall: regsvr32 /u VirtualCam.dll
    echo.
    echo Drop video.mp4 in %%APPDATA%%\VirtualCam\
) else (
    echo [VirtualCam] Build FAILED
    exit /b 1
)
