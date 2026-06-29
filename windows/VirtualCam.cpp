// windows/VirtualCam.cpp
// Full Media Foundation Virtual Camera with video file decoding
// Windows 10 1903+ — compatible with SDK 10.0.26100+

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mfvirtualcamera.h>
#include <mferror.h>
#include <shlobj.h>
#include <knownfolders.h>
#include <stdio.h>
#include <new>
#include <string>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

// ── Video File Reader ──────────────────────────────────────────────────

class VideoFileReader {
private:
    IMFSourceReader* m_pReader;
    int              m_width;
    int              m_height;
    int              m_fps;
    int              m_frameIndex;
    CRITICAL_SECTION m_critSec;

public:
    VideoFileReader() : m_pReader(NULL), m_width(1920), m_height(1080),
                        m_fps(30), m_frameIndex(0) {
        InitializeCriticalSection(&m_critSec);
    }
    ~VideoFileReader() { Close(); DeleteCriticalSection(&m_critSec); }

    BOOL Open(const WCHAR* path) {
        HRESULT hr = MFCreateSourceReaderFromURL(path, NULL, &m_pReader);
        if (FAILED(hr)) {
            wprintf(L"[VirtualCam] Cannot open: %s (0x%08X)\n", path, hr);
            return FALSE;
        }

        IMFMediaType* pType = NULL;
        MFCreateMediaType(&pType);
        pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        hr = m_pReader->SetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, pType);
        pType->Release();

        IMFMediaType* pActual = NULL;
        m_pReader->GetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &pActual);
        if (pActual) {
            UINT32 w = 0, h = 0;
            MFGetAttributeSize(pActual, MF_MT_FRAME_SIZE, &w, &h);
            m_width = (int)w; m_height = (int)h;
            UINT32 num = 0, den = 0;
            MFGetAttributeRatio(pActual, MF_MT_FRAME_RATE, &num, &den);
            if (den > 0) m_fps = num / den;
            pActual->Release();
        }

        m_pReader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
        m_pReader->SetStreamSelection((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);

        wprintf(L"[VirtualCam] Video: %dx%d @ %dfps\n", m_width, m_height, m_fps);
        return TRUE;
    }

    IMFSample* GetNextFrame() {
        EnterCriticalSection(&m_critSec);
        if (!m_pReader) { LeaveCriticalSection(&m_critSec); return NULL; }

        DWORD idx, flags;
        LONGLONG ts;
        IMFSample* pSample = NULL;
        HRESULT hr = m_pReader->ReadSample(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &idx, &flags, &ts, &pSample);

        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            PROPVARIANT var; PropVariantInit(&var);
            var.vt = VT_I8; var.hVal.QuadPart = 0;
            m_pReader->SetCurrentPosition(GUID_NULL, var);
            PropVariantClear(&var);
            m_frameIndex = 0;
            hr = m_pReader->ReadSample(
                (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &idx, &flags, &ts, &pSample);
        }
        if (SUCCEEDED(hr) && pSample) m_frameIndex++;
        LeaveCriticalSection(&m_critSec);
        return pSample;
    }

    void Close() {
        EnterCriticalSection(&m_critSec);
        if (m_pReader) { m_pReader->Release(); m_pReader = NULL; }
        LeaveCriticalSection(&m_critSec);
    }

    int GetWidth() const { return m_width; }
    int GetHeight() const { return m_height; }
    int GetFPS() const { return m_fps; }
};

// ── Helper: find video file ────────────────────────────────────────────

static void FindVideoFile(WCHAR* outPath, size_t outLen) {
    // Try %APPDATA%\VirtualCam\video.mp4
    PWSTR appDataPath = NULL;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, NULL, &appDataPath))) {
        swprintf_s(outPath, outLen, L"%s\\VirtualCam\\video.mp4", appDataPath);
        CoTaskMemFree(appDataPath);
        if (GetFileAttributesW(outPath) != INVALID_FILE_ATTRIBUTES) return;
    }

    // Try Desktop\video.mp4
    PWSTR desktopPath = NULL;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Desktop, 0, NULL, &desktopPath))) {
        swprintf_s(outPath, outLen, L"%s\\video.mp4", desktopPath);
        CoTaskMemFree(desktopPath);
        if (GetFileAttributesW(outPath) != INVALID_FILE_ATTRIBUTES) return;
    }

    // Try current directory
    swprintf_s(outPath, outLen, L"video.mp4");
}

// ── Virtual Camera Media Source ────────────────────────────────────────

// Declare GUID for VirtualCamSource
struct __declspec(uuid("{C2D3E4F5-A6B7-8901-CDEF-1234567890AB}")) VirtualCamSource;

class VirtualCamSource : public IMFMediaSource,
                         public IMFGetService,
                         public IMFMediaEventGenerator {
private:
    LONG               m_refCount;
    CRITICAL_SECTION   m_critSec;
    IMFMediaEventQueue* m_pEventQueue;
    volatile BOOL      m_isShutdown;
    volatile BOOL      m_isStarted;
    HANDLE             m_frameThread;
    volatile BOOL      m_frameThreadRunning;
    int                m_frameIndex;
    VideoFileReader*   m_pReader;
    IMFSample*         m_pCurrentSample;

public:
    VirtualCamSource() : m_refCount(1), m_isShutdown(FALSE),
                         m_isStarted(FALSE), m_frameThread(NULL),
                         m_frameThreadRunning(FALSE), m_frameIndex(0),
                         m_pReader(NULL), m_pCurrentSample(NULL) {
        InitializeCriticalSection(&m_critSec);
        MFCreateEventQueue(&m_pEventQueue);
        m_pReader = new VideoFileReader();

        WCHAR videoPath[MAX_PATH];
        FindVideoFile(videoPath, MAX_PATH);
        m_pReader->Open(videoPath);
    }

    ~VirtualCamSource() {
        Shutdown();
        if (m_pReader) delete m_pReader;
        if (m_pCurrentSample) m_pCurrentSample->Release();
        if (m_pEventQueue) m_pEventQueue->Release();
        DeleteCriticalSection(&m_critSec);
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == __uuidof(IUnknown) ||
            riid == __uuidof(IMFMediaSource) ||
            riid == __uuidof(IMFGetService)) {
            *ppv = static_cast<IMFMediaSource*>(this);
            AddRef(); return S_OK;
        }
        *ppv = NULL; return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refCount); }
    STDMETHODIMP_(ULONG) Release() {
        LONG r = InterlockedDecrement(&m_refCount);
        if (r == 0) delete this;
        return r;
    }

    // IMFMediaEventGenerator (inherited via IMFMediaSource)
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** ppEvent)
        { return m_pEventQueue->GetEvent(flags, ppEvent); }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* st)
        { return m_pEventQueue->BeginGetEvent(cb, st); }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* res, IMFMediaEvent** ppEvent)
        { return m_pEventQueue->EndGetEvent(res, ppEvent); }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID ext, HRESULT hr, const PROPVARIANT* pv)
        { return m_pEventQueue->QueueEventParamVar(t, ext, hr, pv); }

    // IMFMediaSource
    STDMETHODIMP GetCharacteristics(DWORD* pdw) {
        *pdw = MFMEDIASOURCE_IS_LIVE; return S_OK;
    }

    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** ppPD) {
        int w = m_pReader ? m_pReader->GetWidth() : 1920;
        int h = m_pReader ? m_pReader->GetHeight() : 1080;
        int fps = m_pReader ? m_pReader->GetFPS() : 30;

        IMFMediaType* pType = NULL; MFCreateMediaType(&pType);
        pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(pType, MF_MT_FRAME_SIZE, w, h);
        MFSetAttributeRatio(pType, MF_MT_FRAME_RATE, fps, 1);
        MFSetAttributeRatio(pType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        IMFStreamDescriptor* pSD = NULL; MFCreateStreamDescriptor(0, 1, &pType, &pSD);
        pType->Release();
        IMFPresentationDescriptor* pPD = NULL; MFCreatePresentationDescriptor(1, &pSD, &pPD);
        pSD->Release();
        *ppPD = pPD; return S_OK;
    }

    STDMETHODIMP Start(IMFPresentationDescriptor* pPD, const GUID* pFmt, const PROPVARIANT* pPos) {
        m_isStarted = TRUE;
        QueueEvent(MESourceStarted, GUID_NULL, S_OK, NULL);
        if (!m_frameThreadRunning) {
            m_frameThreadRunning = TRUE;
            m_frameThread = CreateThread(NULL, 0, FramePumpThread, this, 0, NULL);
        }
        return S_OK;
    }
    STDMETHODIMP Stop() {
        m_isStarted = FALSE; m_frameThreadRunning = FALSE;
        if (m_frameThread) { WaitForSingleObject(m_frameThread, 5000); CloseHandle(m_frameThread); m_frameThread = NULL; }
        return S_OK;
    }
    STDMETHODIMP Pause() { return S_OK; }
    STDMETHODIMP Shutdown() {
        Stop(); m_isShutdown = TRUE; m_pEventQueue->Shutdown(); return S_OK;
    }

    // IMFGetService
    STDMETHODIMP GetService(REFGUID guidService, REFIID riid, LPVOID* ppv) {
        // Return our media source for virtual camera requests
        return QueryInterface(riid, ppv);
    }

    static DWORD WINAPI FramePumpThread(LPVOID param) {
        VirtualCamSource* src = (VirtualCamSource*)param;
        int fps = src->m_pReader ? src->m_pReader->GetFPS() : 30;
        while (src->m_frameThreadRunning) {
            IMFSample* sample = src->m_pReader->GetNextFrame();
            if (sample) {
                EnterCriticalSection(&src->m_critSec);
                if (src->m_pCurrentSample) src->m_pCurrentSample->Release();
                src->m_pCurrentSample = sample; sample->AddRef();
                src->m_frameIndex++;
                LeaveCriticalSection(&src->m_critSec);
                sample->Release();
            }
            Sleep(1000 / fps);
        }
        return 0;
    }
};

// ── COM Registration ──────────────────────────────────────────────────

HRESULT RegisterVirtualCamera() {
    IMFVirtualCamera* pCam = NULL;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"Integrated Camera",
        L"VirtualCam_Device_001",
        NULL,  // default category
        0,
        &pCam);

    if (FAILED(hr)) {
        wprintf(L"[VirtualCam] MFCreateVirtualCamera failed: 0x%08X\n", hr);
        return hr;
    }

    wprintf(L"[VirtualCam] Camera 'Integrated Camera' created successfully.\n");
    wprintf(L"[VirtualCam] Drop video.mp4 in %%APPDATA%%\\VirtualCam\\\n");
    wprintf(L"[VirtualCam] Camera active. Open apps to use.\n");

    pCam->Release();
    return S_OK;
}

HRESULT UnregisterVirtualCamera() {
    IMFVirtualCamera* pCam = NULL;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"Integrated Camera",
        L"VirtualCam_Device_001",
        NULL,
        0,
        &pCam);

    if (SUCCEEDED(hr)) {
        hr = pCam->Shutdown();
        pCam->Release();
        wprintf(L"[VirtualCam] Camera removed.\n");
    }
    return hr;
}

// ── DLL Entry Points ──────────────────────────────────────────────────

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID reserved) {
    switch (reason) {
    case DLL_PROCESS_ATTACH: MFStartup(MF_VERSION); break;
    case DLL_PROCESS_DETACH: MFShutdown(); break;
    }
    return TRUE;
}

STDAPI DllRegisterServer()   { return RegisterVirtualCamera(); }
STDAPI DllUnregisterServer() { return UnregisterVirtualCamera(); }
