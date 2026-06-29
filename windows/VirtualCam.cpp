// windows/VirtualCam.cpp
// Full Media Foundation Virtual Camera with video file decoding
// Windows 10 1903+ required

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mfvirtualcamera.h>
#include <mferror.h>
#include <shlwapi.h>
#include <stdio.h>
#include <new>
#include <vector>
#include <string>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "shlwapi.lib")

// ── Video File Reader ──────────────────────────────────────────────────

class VideoFileReader {
private:
    IMFSourceReader* m_pReader;
    int              m_width;
    int              m_height;
    int              m_fps;
    LONGLONG         m_duration;
    int              m_frameIndex;
    CRITICAL_SECTION m_critSec;

public:
    VideoFileReader() : m_pReader(NULL), m_width(1920), m_height(1080),
                        m_fps(30), m_duration(0), m_frameIndex(0) {
        InitializeCriticalSection(&m_critSec);
    }

    ~VideoFileReader() {
        Close();
        DeleteCriticalSection(&m_critSec);
    }

    BOOL Open(const WCHAR* path) {
        HRESULT hr = MFCreateSourceReaderFromURL(path, NULL, &m_pReader);
        if (FAILED(hr)) {
            wprintf(L"[VirtualCam] Cannot open video: %s (0x%08X)\n", path, hr);
            return FALSE;
        }

        // Configure output format: NV12, same resolution as source
        IMFMediaType* pType = NULL;
        MFCreateMediaType(&pType);
        pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);

        hr = m_pReader->SetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, pType);
        pType->Release();

        if (FAILED(hr)) {
            // Fallback: don't set media type, use source default
            wprintf(L"[VirtualCam] Custom format failed, using source default\n");
        }

        // Get actual media type
        IMFMediaType* pActualType = NULL;
        m_pReader->GetCurrentMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &pActualType);
        if (pActualType) {
            MFGetAttributeSize(pActualType, MF_MT_FRAME_SIZE, (UINT32*)&m_width, (UINT32*)&m_height);
            UINT32 num = 0, den = 0;
            MFGetAttributeRatio(pActualType, MF_MT_FRAME_RATE, &num, &den);
            if (den > 0) m_fps = num / den;
            pActualType->Release();
        }

        // Get duration
        IMFPresentationDescriptor* pPD = NULL;
        m_pReader->GetPresentationAttribute(
            (DWORD)MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, NULL);
        PROPVARIANT var;
        PropVariantInit(&var);
        hr = m_pReader->GetPresentationAttribute(
            (DWORD)MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var);
        if (SUCCEEDED(hr)) {
            m_duration = var.hVal.QuadPart;
        }
        PropVariantClear(&var);

        // Loop the video
        m_pReader->SetStreamSelection(
            (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
        m_pReader->SetStreamSelection(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);

        wprintf(L"[VirtualCam] Video opened: %dx%d @ %dfps\n", m_width, m_height, m_fps);
        return TRUE;
    }

    IMFSample* GetNextFrame() {
        EnterCriticalSection(&m_critSec);
        if (!m_pReader) {
            LeaveCriticalSection(&m_critSec);
            return NULL;
        }

        DWORD streamIndex, flags;
        LONGLONG timestamp;
        IMFSample* pSample = NULL;

        HRESULT hr = m_pReader->ReadSample(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
            0, &streamIndex, &flags, &timestamp, &pSample);

        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            // Loop: restart from beginning
            PROPVARIANT var;
            PropVariantInit(&var);
            var.vt = VT_I8;
            var.hVal.QuadPart = 0;
            m_pReader->SetCurrentPosition(GUID_NULL, var);
            PropVariantClear(&var);
            m_frameIndex = 0;

            // Try reading again
            hr = m_pReader->ReadSample(
                (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                0, &streamIndex, &flags, &timestamp, &pSample);
        }

        if (SUCCEEDED(hr) && pSample) {
            m_frameIndex++;
        }

        LeaveCriticalSection(&m_critSec);
        return pSample;
    }

    void Close() {
        EnterCriticalSection(&m_critSec);
        if (m_pReader) {
            m_pReader->Release();
            m_pReader = NULL;
        }
        LeaveCriticalSection(&m_critSec);
    }

    int GetWidth()  const { return m_width; }
    int GetHeight() const { return m_height; }
    int GetFPS()    const { return m_fps; }
};

// ── Virtual Camera Media Source ────────────────────────────────────────

class VirtualCamSource : public IMFMediaSource,
                         public IMFGetService,
                         public IMFMediaEventGenerator {
private:
    LONG              m_refCount;
    CRITICAL_SECTION  m_critSec;
    IMFMediaEventQueue* m_pEventQueue;
    volatile BOOL     m_isShutdown;
    volatile BOOL     m_isStarted;
    HANDLE            m_frameThread;
    volatile BOOL     m_frameThreadRunning;
    int               m_frameIndex;
    VideoFileReader*  m_pReader;
    IMFSample*        m_pCurrentSample;

public:
    VirtualCamSource() : m_refCount(1), m_isShutdown(FALSE),
                         m_isStarted(FALSE), m_frameThread(NULL),
                         m_frameThreadRunning(FALSE), m_frameIndex(0),
                         m_pReader(NULL), m_pCurrentSample(NULL) {
        InitializeCriticalSection(&m_critSec);
        MFCreateEventQueue(&m_pEventQueue);

        m_pReader = new VideoFileReader();

        // Find video file
        WCHAR videoPath[MAX_PATH];
        WCHAR appData[MAX_PATH];
        if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_APPDATA, NULL, 0, appData))) {
            swprintf_s(videoPath, L"%s\\VirtualCam\\video.mp4", appData);
        }
        if (!m_pReader->Open(videoPath)) {
            // Try Desktop
            WCHAR desktop[MAX_PATH];
            if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_DESKTOP, NULL, 0, desktop))) {
                swprintf_s(videoPath, L"%s\\video.mp4", desktop);
                m_pReader->Open(videoPath);
            }
        }
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
            riid == __uuidof(IMFMediaEventGenerator) ||
            riid == __uuidof(IMFGetService)) {
            *ppv = static_cast<IMFMediaSource*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refCount); }
    STDMETHODIMP_(ULONG) Release() {
        LONG ref = InterlockedDecrement(&m_refCount);
        if (ref == 0) delete this;
        return ref;
    }

    // IMFMediaEventGenerator
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** ppEvent)
        { return m_pEventQueue->GetEvent(flags, ppEvent); }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* state)
        { return m_pEventQueue->BeginGetEvent(cb, state); }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** ppEvent)
        { return m_pEventQueue->EndGetEvent(result, ppEvent); }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID ext, HRESULT hr, const PROPVARIANT* pv)
        { return m_pEventQueue->QueueEventParamVar(t, ext, hr, pv); }

    // IMFMediaSource
    STDMETHODIMP GetCharacteristics(DWORD* pdw) {
        *pdw = MFMEDIASOURCE_IS_LIVE;
        return S_OK;
    }

    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** ppPD) {
        int w = m_pReader ? m_pReader->GetWidth() : 1920;
        int h = m_pReader ? m_pReader->GetHeight() : 1080;
        int fps = m_pReader ? m_pReader->GetFPS() : 30;

        IMFMediaType* pType = NULL;
        MFCreateMediaType(&pType);
        pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(pType, MF_MT_FRAME_SIZE, w, h);
        MFSetAttributeRatio(pType, MF_MT_FRAME_RATE, fps, 1);
        MFSetAttributeRatio(pType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

        IMFStreamDescriptor* pSD = NULL;
        MFCreateStreamDescriptor(0, 1, &pType, &pSD);
        pType->Release();

        IMFPresentationDescriptor* pPD = NULL;
        MFCreatePresentationDescriptor(1, &pSD, &pPD);
        pSD->Release();

        *ppPD = pPD;
        return S_OK;
    }

    STDMETHODIMP Start(IMFPresentationDescriptor* pPD,
                       const GUID* pguidTimeFormat,
                       const PROPVARIANT* pStartPos) {
        m_isStarted = TRUE;
        QueueEvent(MEStreamStarted, GUID_NULL, S_OK, NULL);

        if (!m_frameThreadRunning) {
            m_frameThreadRunning = TRUE;
            m_frameThread = CreateThread(NULL, 0, FramePumpThread, this, 0, NULL);
        }
        return S_OK;
    }

    STDMETHODIMP Stop() {
        m_isStarted = FALSE;
        m_frameThreadRunning = FALSE;
        if (m_frameThread) {
            WaitForSingleObject(m_frameThread, 5000);
            CloseHandle(m_frameThread);
            m_frameThread = NULL;
        }
        return S_OK;
    }
    STDMETHODIMP Pause() { return S_OK; }
    STDMETHODIMP Shutdown() {
        Stop();
        m_isShutdown = TRUE;
        m_pEventQueue->Shutdown();
        return S_OK;
    }

    // IMFGetService
    STDMETHODIMP GetService(REFGUID guidService, REFIID riid, LPVOID* ppv) {
        if (guidService == MF_VIRTUALCAMERA_PROVIDER_SERVICE)
            return QueryInterface(riid, ppv);
        return MF_E_UNSUPPORTED_SERVICE;
    }

    // Frame pump
    static DWORD WINAPI FramePumpThread(LPVOID param) {
        VirtualCamSource* src = (VirtualCamSource*)param;
        int fps = src->m_pReader ? src->m_pReader->GetFPS() : 30;

        while (src->m_frameThreadRunning) {
            IMFSample* sample = src->m_pReader->GetNextFrame();
            if (sample) {
                EnterCriticalSection(&src->m_critSec);
                if (src->m_pCurrentSample) src->m_pCurrentSample->Release();
                src->m_pCurrentSample = sample;
                src->m_frameIndex++;
                LeaveCriticalSection(&src->m_critSec);
            }
            Sleep(1000 / fps);
        }
        return 0;
    }
};

// ── COM Registration ──────────────────────────────────────────────────

HRESULT RegisterVirtualCamera() {
    IMFAttributes* pAttr = NULL;
    MFCreateAttributes(&pAttr, 4);
    pAttr->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                    L"VirtualCam_Device");
    pAttr->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                  MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    pAttr->SetString(MF_VIRTUALCAMERA_NAME, L"Integrated Camera");
    pAttr->SetGUID(MF_VIRTUALCAMERA_PROVIDER_SERVICE,
                  __uuidof(VirtualCamSource));

    IMFVirtualCamera* pCam = NULL;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"VirtualCam",
        L"{B2C3D4E5-F6A7-8901-BCDE-F12345678901}",
        NULL, 0, NULL, &pCam);

    if (SUCCEEDED(hr)) hr = pCam->Register(pAttr);
    if (pCam) pCam->Release();
    if (pAttr) pAttr->Release();

    if (SUCCEEDED(hr))
        wprintf(L"[VirtualCam] Registered. Drop video.mp4 in %%APPDATA%%\\VirtualCam\\\n");
    else
        wprintf(L"[VirtualCam] Register failed: 0x%08X\n", hr);
    return hr;
}

HRESULT UnregisterVirtualCamera() {
    IMFVirtualCamera* pCam = NULL;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"VirtualCam",
        L"{B2C3D4E5-F6A7-8901-BCDE-F12345678901}",
        NULL, 0, NULL, &pCam);

    if (SUCCEEDED(hr)) {
        pCam->Unregister();
        pCam->Release();
    }
    return hr;
}

// ── DLL Entry Points ──────────────────────────────────────────────────

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    switch (reason) {
    case DLL_PROCESS_ATTACH: MFStartup(MF_VERSION); break;
    case DLL_PROCESS_DETACH: MFShutdown(); break;
    }
    return TRUE;
}

STDAPI DllRegisterServer()   { return SUCCEEDED(RegisterVirtualCamera()) ? S_OK : E_FAIL; }
STDAPI DllUnregisterServer() { return SUCCEEDED(UnregisterVirtualCamera()) ? S_OK : E_FAIL; }
