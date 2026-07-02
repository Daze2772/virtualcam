# Virtual Camera Driver

System-level virtual camera drivers for **macOS** and **Windows**.
Appears as a genuine hardware camera device — indistinguishable from built-in webcam.
Plays pre-recorded video files. Works with any application.



## Architecture

```
┌─────────────────────────────────┐
│  User Application               │
│  (Chrome, Zoom, OnlyFans, etc.) │
└──────────┬──────────────────────┘
           │ enumerateDevices / getUserMedia
           ▼
┌─────────────────────────────────┐
│  OS Camera Framework            │
│  (CoreMediaIO / MediaFoundation) │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│  VIRTUAL CAMERA DRIVER          │
│  • Appears as hardware device   │
│  • Reads video file frame-by-frame │
│  • Produces authentic stream metadata │
│  • Zero JS/CSP/iframe limitations │
└─────────────────────────────────┘
```

## macOS

### Build
```bash
cd macos
make
```

### Install
```bash
sudo cp -R VirtualCam.plugin /Library/CoreMediaIO/Plug-Ins/DAL/
```

### Uninstall
```bash
sudo rm -rf /Library/CoreMediaIO/Plug-Ins/DAL/VirtualCam.plugin
```

### Requirements
- macOS 11.0+
- Xcode Command Line Tools
- Code signing certificate (for distribution)

## Windows

### Build
```cmd
cd windows
build.bat
```

### Install
```cmd
regsvr32 VirtualCam.dll
```

### Uninstall
```cmd
regsvr32 /u VirtualCam.dll
```

### Requirements
- Windows 10 1903+ (for Media Foundation Virtual Camera)
- Windows SDK 10.0.19041+
- Visual Studio Build Tools 2022+

## Video Source
The driver reads `.mp4`, `.mov`, or `.webm` video files. Place a video file at:
- **macOS:** `~/Library/Application Support/VirtualCam/video.mp4`
- **Windows:** `%APPDATA%\VirtualCam\video.mp4`

Use the companion config app to switch videos and toggle the camera on/off.

## Detection Resistance
- Uses real CoreMediaIO / DirectShow device registration (not JS patching)
- Hardware-identical stream metadata
- Native pixel buffers from actual video decoder
- Appears in system camera list alongside real devices
- No browser extension required (works in any app)
