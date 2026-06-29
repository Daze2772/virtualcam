// windows/VirtualCam.cpp
// Media Foundation Virtual Camera Driver for Windows 10 1903+
// Appears as a genuine hardware camera device

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfvirtualcamera.h>
#include <mferror.h>
#include <shlwapi.h>
#include <stdio.h>
#include <new>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "shlwapi.lib")

// ── Virtual Camera Class ──────────────────────────────────────────────

class VirtualCamMediaSource : public IMFMediaSource,
                              public IMFGetService,
                              public IMFMediaEventGenerator {
private:
    LONG              m_refCount;
    CRITICAL_SECTION  m_critSec;
    IMFAttributes*    m_pAttributes;
    IMFMediaEventQueue* m_pEventQueue;
    volatile BOOL     m_isShutdown;
    volatile BOOL     m_isStarted;
    HANDLE            m_frameThread;
    volatile BOOL     m_frameThreadRunning;
    int               m_frameIndex;

    static const WCHAR* CAMERA_NAME;
    static const WCHAR* CAMERA_UID;
    static const int    DEFAULT_WIDTH  = 1920;
    static const int    DEFAULT_HEIGHT = 1080;
    static const int    DEFAULT_FPS    = 30;

public:
    VirtualCamMediaSource() : m_refCount(1), m_isShutdown(FALSE),
                              m_isStarted(FALSE), m_frameThread(NULL),
                              m_frameThreadRunning(FALSE), m_frameIndex(0) {
        InitializeCriticalSection(&m_critSec);
        MFCreateAttributes(&m_pAttributes, 0);
        MFCreateEventQueue(&m_pEventQueue);
    }

    ~VirtualCamMediaSource() {
        Shutdown();
        if (m_pAttributes) m_pAttributes->Release();
        if (m_pEventQueue) m_pEventQueue->Release();
        DeleteCriticalSection(&m_critSec);
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFMediaSource) ||
            riid == __uuidof(IMFMediaEventGenerator) || riid == __uuidof(IMFGetService)) {
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
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** ppEvent) {
        return m_pEventQueue->GetEvent(flags, ppEvent);
    }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* pCallback, IUnknown* pState) {
        return m_pEventQueue->BeginGetEvent(pCallback, pState);
    }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* pResult, IMFMediaEvent** ppEvent) {
        return m_pEventQueue->EndGetEvent(pResult, ppEvent);
    }
    STDMETHODIMP QueueEvent(MediaEventType event, REFGUID extType, HRESULT hr, const PROPVARIANT* pv) {
        return m_pEventQueue->QueueEventParamVar(event, extType, hr, pv);
    }

    // IMFMediaSource
    STDMETHODIMP GetCharacteristics(DWORD* pdwCharacteristics) {
        *pdwCharacteristics = MFMEDIASOURCE_IS_LIVE;
        return S_OK;
    }
    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** ppPD) {
        // Create a single-stream presentation descriptor
        IMFStreamDescriptor* pSD = NULL;
        IMFPresentationDescriptor* pPD = NULL;

        // Build media type: 1920x1080 NV12 @ 30fps
        IMFMediaType* pType = NULL;
        MFCreateMediaType(&pType);
        pType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(pType, MF_MT_FRAME_SIZE, DEFAULT_WIDTH, DEFAULT_HEIGHT);
        MFSetAttributeRatio(pType, MF_MT_FRAME_RATE, DEFAULT_FPS, 1);
        MFSetAttributeRatio(pType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

        MFCreateStreamDescriptor(0, 1, &pType, &pSD);
        pType->Release();

        MFCreatePresentationDescriptor(1, &pSD, &pPD);
        pSD->Release();

        *ppPD = pPD;
        return S_OK;
    }
    STDMETHODIMP Start(IMFPresentationDescriptor* pPD, const GUID* pguidTimeFormat, const PROPVARIANT* pStartPos) {
        m_isStarted = TRUE;
        QueueEvent(MEStreamStarted, GUID_NULL, S_OK, NULL);

        // Start frame pump thread
        if (!m_frameThreadRunning) {
            m_frameThreadRunning = TRUE;
            m_frameThread = CreateThread(NULL, 0, FramePumpThreadProc, this, 0, NULL);
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
        QueueEvent(MEStreamStopped, GUID_NULL, S_OK, NULL);
        return S_OK;
    }
    STDMETHODIMP Pause() { return S_OK; }
    STDMETHODIMP Shutdown() {
        Stop();
        m_isShutdown = TRUE;
        if (m_pEventQueue) m_pEventQueue->Shutdown();
        return S_OK;
    }

    // IMFGetService
    STDMETHODIMP GetService(REFGUID guidService, REFIID riid, LPVOID* ppv) {
        if (guidService == MF_VIRTUALCAMERA_PROVIDER_SERVICE) {
            return QueryInterface(riid, ppv);
        }
        return MF_E_UNSUPPORTED_SERVICE;
    }

    // Frame pump — reads video file and delivers samples
    static DWORD WINAPI FramePumpThreadProc(LPVOID param) {
        VirtualCamMediaSource* src = (VirtualCamMediaSource*)param;
        int frameIndex = 0;

        while (src->m_frameThreadRunning) {
            // In production: decode next frame from video file
            // For skeleton: deliver a blank frame
            Sleep(1000 / DEFAULT_FPS);
            frameIndex++;
        }
        return 0;
    }
};

const WCHAR* VirtualCamMediaSource::CAMERA_NAME = L"Integrated Camera";
const WCHAR* VirtualCamMediaSource::CAMERA_UID  = L"{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}";

// ── Virtual Camera Registration ────────────────────────────────────────

HRESULT RegisterVirtualCamera() {
    // Use IMFVirtualCamera::Create to register our custom media source
    // Requires Windows 10 1903+ and the virtual camera API

    IMFVirtualCamera* pCamera = NULL;
    IMFAttributes* pAttributes = NULL;

    MFCreateAttributes(&pAttributes, 4);
    pAttributes->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                          L"VirtualCam_Device");
    pAttributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    pAttributes->SetString(MF_VIRTUALCAMERA_NAME, L"Integrated Camera");
    pAttributes->SetGUID(MF_VIRTUALCAMERA_PROVIDER_SERVICE,
                        __uuidof(VirtualCamMediaSource));

    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"VirtualCam",
        L"{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}",
        NULL,
        0,
        NULL,
        &pCamera);

    if (SUCCEEDED(hr)) {
        pCamera->Register(pAttributes);
        pCamera->Release();
        wprintf(L"[VirtualCam] Camera registered successfully\n");
    } else {
        wprintf(L"[VirtualCam] Registration failed: 0x%08X\n", hr);
    }

    if (pAttributes) pAttributes->Release();
    return hr;
}

HRESULT UnregisterVirtualCamera() {
    IMFVirtualCamera* pCamera = NULL;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_CurrentUser,
        L"VirtualCam",
        L"{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}",
        NULL,
        0,
        NULL,
        &pCamera);

    if (SUCCEEDED(hr)) {
        pCamera->Unregister();
        pCamera->Release();
        wprintf(L"[VirtualCam] Camera unregistered\n");
    }
    return hr;
}

// ── Entry Point (DLL) ─────────────────────────────────────────────────

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        MFStartup(MF_VERSION);
        break;
    case DLL_PROCESS_DETACH:
        MFShutdown();
        break;
    }
    return TRUE;
}

// COM registration
STDAPI DllRegisterServer() {
    return SUCCEEDED(RegisterVirtualCamera()) ? S_OK : E_FAIL;
}

STDAPI DllUnregisterServer() {
    return SUCCEEDED(UnregisterVirtualCamera()) ? S_OK : E_FAIL;
}
