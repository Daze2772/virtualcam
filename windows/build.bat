@echo off
echo [VirtualCam] Building...

set CL=/EHsc /O2 /MT /DNDEBUG /DUNICODE /D_UNICODE
set LINKFLAGS=/DLL kernel32.lib mfplat.lib mfreadwrite.lib mf.lib mfsensorgroup.lib runtimeobject.lib shlwapi.lib shell32.lib ole32.lib

cl %CL% VirtualCam.cpp /FeVirtualCam.dll /link %LINKFLAGS% /DEF:VirtualCam.def

if %ERRORLEVEL% NEQ 0 (
    echo [VirtualCam] Build FAILED
    exit /b 1
)

echo.
echo [VirtualCam] Build successful - VirtualCam.dll
echo.
echo To install:
echo   regsvr32 VirtualCam.dll
echo.
echo To uninstall:
echo   regsvr32 /u VirtualCam.dll
echo.
echo Drop video.mp4 in %%APPDATA%%\VirtualCam\
