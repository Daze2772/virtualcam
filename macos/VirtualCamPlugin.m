//  VirtualCamPlugin.m — Complete CoreMediaIO DAL Virtual Camera
//  Fully implemented CMIOHardwarePlugIn with stream support
//  Build: make  |  Install: sudo make install

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardwarePlugIn.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <pthread.h>

#pragma mark - Constants

#define kDeviceUID      "VirtualCam_Device_UID"
#define kModelUID       "VirtualCam_Model_UID"
#define kDeviceName     "Integrated Camera"
#define kMfr            "VirtualCam"
#define kWidth  1920
#define kHeight 1080
#define kFPS    30

#pragma mark - Objects

typedef struct {
    CMIOObjectID   objectID;
    void          *owner;
} BaseObject;

typedef struct {
    BaseObject     base;
} PlugInObject;

typedef struct {
    BaseObject     base;
} DeviceObject;

typedef struct {
    BaseObject      base;
    CMSimpleQueueRef queue;
    CVPixelBufferPoolRef pool;
    CMVideoFormatDescriptionRef formatDesc;
    pthread_t       thread;
    volatile int    running;
    volatile int    frameIndex;
    AVAssetReader  *reader;
    AVAssetReaderTrackOutput *trackOutput;
    BOOL            videoLoaded;
    int             width, height;
} StreamObject;

#pragma mark - Globals

static PlugInObject   gPlugInObj    = {{1}};
static DeviceObject   gDeviceObj    = {{2}};
static StreamObject   gStreamObj    = {{3}};
static CMIOHardwarePlugInInterface *gInterface = NULL;
static NSLock *gLock = nil;

#pragma mark - Video Source

static BOOL LoadVideo(StreamObject *s) {
    NSString *p = [@"~/Library/Application Support/VirtualCam/video.mp4" stringByExpandingTildeInPath];
    NSURL *u = [NSURL fileURLWithPath:p];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSLog(@"[VirtualCam] No video at %@, using test pattern", p);
        return NO;
    }
    AVAsset *asset = [AVAsset assetWithURL:u];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return NO;
    s->width = (int)track.naturalSize.width;
    s->height = (int)track.naturalSize.height;
    NSDictionary *sets = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    NSError *err = nil;
    s->reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (err) return NO;
    s->trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:sets];
    s->trackOutput.alwaysCopiesSampleData = NO;
    [s->reader addOutput:s->trackOutput];
    [s->reader startReading];
    s->videoLoaded = YES;
    NSLog(@"[VirtualCam] Video: %dx%d", s->width, s->height);
    return YES;
}

static CMSampleBufferRef NextFrame(StreamObject *s) {
    if (s->videoLoaded && s->trackOutput) {
        CMSampleBufferRef f = [s->trackOutput copyNextSampleBuffer];
        if (!f && s->reader.status == AVAssetReaderStatusCompleted) {
            [s->reader cancelReading];
            AVAsset *asset = s->reader.asset;
            NSError *err = nil;
            s->reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
            if (!err) {
                s->trackOutput = [[AVAssetReaderTrackOutput alloc]
                    initWithTrack:[asset tracksWithMediaType:AVMediaTypeVideo].firstObject
                    outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
                [s->reader addOutput:s->trackOutput];
                [s->reader startReading];
                f = [s->trackOutput copyNextSampleBuffer];
            }
        }
        return f;
    }
    return NULL;
}

static void *PumpThread(void *arg) {
    StreamObject *s = (StreamObject *)arg;
    s->frameIndex = 0;
    while (s->running) {
        @autoreleasepool {
            CMSampleBufferRef sb = NULL;
            CMTime pts = CMTimeMake(s->frameIndex, kFPS);

            CMSampleBufferRef frame = NextFrame(s);
            if (frame) {
                CMSampleTimingInfo timing;
                CMSampleBufferGetSampleTimingInfo(frame, 0, &timing);
                timing.presentationTimeStamp = pts;
                CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, frame, 1, &timing, &sb);
                CFRelease(frame);
            }

            if (!sb) {
                CVPixelBufferRef buf = NULL;
                CVPixelBufferPoolCreatePixelBuffer(NULL, s->pool, &buf);
                if (buf) {
                    CVPixelBufferLockBaseAddress(buf, 0);
                    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
                    size_t rb = CVPixelBufferGetBytesPerRow(buf);
                    unsigned char *b = CVPixelBufferGetBaseAddress(buf);
                    int bx = (s->frameIndex * 4) % (int)w;
                    for (size_t y = 0; y < h; y++) {
                        unsigned char *r = b + y * rb;
                        for (size_t x = 0; x < w; x++) {
                            int i = (int)(x * 4);
                            if (x >= (size_t)bx && x < (size_t)(bx + 200)) {
                                r[i]=233; r[i+1]=69; r[i+2]=96; r[i+3]=255;
                            } else {
                                r[i]=26; r[i+1]=26; r[i+2]=40; r[i+3]=255;
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buf, 0);
                    CMSampleTimingInfo t = {.duration=CMTimeMake(1,kFPS), .presentationTimeStamp=pts, .decodeTimeStamp=kCMTimeInvalid};
                    CMVideoFormatDescriptionRef fd = NULL;
                    CMVideoFormatDescriptionCreateForImageBuffer(NULL, buf, &fd);
                    CMSampleBufferCreateReadyWithImageBuffer(NULL, buf, fd, &t, &sb);
                    if (fd) CFRelease(fd);
                    CVPixelBufferRelease(buf);
                }
            }
            if (sb) {
                while (CMSimpleQueueGetFullness(s->queue) >= 0.8f) usleep(1000);
                CMSimpleQueueEnqueue(s->queue, sb);
                CFRelease(sb);
            }
        }
        s->frameIndex++;
        usleep(1000000 / kFPS);
    }
    return NULL;
}

#pragma mark - Interface Implementation

// IUnknown
static HRESULT QueryInterface(void *self, REFIID uuid, LPVOID *iface) { *iface = gInterface; return 0; }
static UInt32   AddRef(void *self) { return 1; }
static UInt32   Release_(void *self) { return 1; }

// Object management
static UInt32 GetNumberObjects(CMIOHardwarePlugInRef self) { return 3; }
static OSStatus GetClassID(CMIOHardwarePlugInRef self, CMIOObjectID id, CMIOClassID *cid) {
    if (id == 1) *cid = kCMIOPlugInClassID;
    else if (id == 2) *cid = kCMIODeviceClassID;
    else if (id == 3) *cid = kCMIOStreamClassID;
    else return kCMIOHardwareBadObjectError;
    return 0;
}

// Device properties
static Boolean DeviceHasProperty(DeviceObject *d, const CMIOObjectPropertyAddress *a) {
    return (a->mSelector == kCMIODevicePropertyDeviceUID ||
            a->mSelector == kCMIODevicePropertyModelUID ||
            a->mSelector == kCMIODevicePropertyDeviceIsAlive ||
            a->mSelector == kCMIODevicePropertyStreams ||
            a->mSelector == kCMIODevicePropertyDeviceMaster);
}

static OSStatus DeviceGetProperty(DeviceObject *d, const CMIOObjectPropertyAddress *a,
                                   UInt32 qs, const void *q, UInt32 ds, UInt32 *du, void *data) {
    if (a->mSelector == kCMIODevicePropertyDeviceUID) {
        CFStringRef s = CFSTR(kDeviceUID);
        if (ds >= sizeof(CFStringRef)) { *(CFStringRef *)data = s; if (du) *du = sizeof(CFStringRef); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIODevicePropertyModelUID) {
        CFStringRef s = CFSTR(kModelUID);
        if (ds >= sizeof(CFStringRef)) { *(CFStringRef *)data = s; if (du) *du = sizeof(CFStringRef); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIODevicePropertyDeviceIsAlive) {
        if (ds >= sizeof(UInt32)) { *(UInt32 *)data = 1; if (du) *du = sizeof(UInt32); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIODevicePropertyStreams) {
        if (ds >= sizeof(CMIOStreamID)) {
            CMIOStreamID sid = 3;
            memcpy(data, &sid, sizeof(sid));
            if (du) *du = sizeof(CMIOStreamID);
            return 0;
        }
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIODevicePropertyDeviceMaster) {
        SInt32 v = -1;
        if (ds >= sizeof(SInt32)) { *(SInt32 *)data = v; if (du) *du = sizeof(SInt32); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    return kCMIOHardwareUnknownPropertyError;
}

// Stream properties
static Boolean StreamHasProperty(StreamObject *s, const CMIOObjectPropertyAddress *a) {
    return (a->mSelector == kCMIOStreamPropertyDirection ||
            a->mSelector == kCMIOStreamPropertyTerminalType ||
            a->mSelector == kCMIOStreamPropertyStartingChannel ||
            a->mSelector == kCMIOStreamPropertyFormatDescription ||
            a->mSelector == kCMIOStreamPropertyFormatDescriptions ||
            a->mSelector == kCMIOStreamPropertyFrameRate ||
            a->mSelector == kCMIOStreamPropertyFrameRates);
}

static OSStatus StreamGetProperty(StreamObject *s, const CMIOObjectPropertyAddress *a,
                                   UInt32 qs, const void *q, UInt32 ds, UInt32 *du, void *data) {
    if (a->mSelector == kCMIOStreamPropertyDirection) {
        UInt32 v = 0; // output
        if (ds >= sizeof(UInt32)) { *(UInt32 *)data = v; if (du) *du = sizeof(UInt32); return 0; }
    }
    if (a->mSelector == kCMIOStreamPropertyTerminalType) {
        UInt32 v = 'vdig';
        if (ds >= sizeof(UInt32)) { *(UInt32 *)data = v; if (du) *du = sizeof(UInt32); return 0; }
    }
    if (a->mSelector == kCMIOStreamPropertyStartingChannel) {
        UInt32 v = 1;
        if (ds >= sizeof(UInt32)) { *(UInt32 *)data = v; if (du) *du = sizeof(UInt32); return 0; }
    }
    if (a->mSelector == kCMIOStreamPropertyFormatDescriptions) {
        CMFormatDescriptionRef desc = s->formatDesc;
        CFRetain(desc);
        CMFormatDescriptionRef *arr = (CMFormatDescriptionRef *)data;
        if (ds >= sizeof(CMFormatDescriptionRef)) {
            arr[0] = desc;
            if (du) *du = sizeof(CMFormatDescriptionRef);
            return 0;
        }
        CFRelease(desc);
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIOStreamPropertyFormatDescription) {
        CMFormatDescriptionRef desc = s->formatDesc;
        CFRetain(desc);
        if (ds >= sizeof(CMFormatDescriptionRef)) {
            *(CMFormatDescriptionRef *)data = desc;
            if (du) *du = sizeof(CMFormatDescriptionRef);
            return 0;
        }
        CFRelease(desc);
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIOStreamPropertyFrameRate) {
        Float64 v = kFPS;
        if (ds >= sizeof(Float64)) { *(Float64 *)data = v; if (du) *du = sizeof(Float64); return 0; }
    }
    return kCMIOHardwareUnknownPropertyError;
}

// Stream control
static OSStatus StreamStart(StreamObject *s) {
    if (s->running) return 0;
    s->running = 1;
    pthread_create(&s->thread, NULL, PumpThread, s);
    return 0;
}

static OSStatus StreamStop(StreamObject *s) {
    s->running = 0;
    pthread_join(s->thread, NULL);
    return 0;
}

static OSStatus StreamCopyBufferQueue(StreamObject *s, CMIODeviceStreamQueueAlteredProc p, void *rc, CMSimpleQueueRef *q) {
    *q = s->queue;
    CFRetain(s->queue);
    return 0;
}

// Generic property dispatch
static Boolean HasProperty(CMIOHardwarePlugInRef p, CMIOObjectID id, const CMIOObjectPropertyAddress *a) {
    if (id == 2) return DeviceHasProperty(NULL, a);
    if (id == 3) return StreamHasProperty(NULL, a);
    return false;
}

static OSStatus IsPropertySettable(CMIOHardwarePlugInRef p, CMIOObjectID id, const CMIOObjectPropertyAddress *a, Boolean *out) {
    *out = false;
    return 0;
}

static OSStatus GetPropertyData(CMIOHardwarePlugInRef p, CMIOObjectID id, const CMIOObjectPropertyAddress *a,
                                 UInt32 qs, const void *q, UInt32 ds, UInt32 *du, void *data) {
    if (id == 2) return DeviceGetProperty(NULL, a, qs, q, ds, du, data);
    if (id == 3) return StreamGetProperty(NULL, a, qs, q, ds, du, data);
    return kCMIOHardwareBadObjectError;
}

static OSStatus SetPropertyData(CMIOHardwarePlugInRef p, CMIOObjectID id, const CMIOObjectPropertyAddress *a,
                                 UInt32 qs, const void *q, UInt32 ds, const void *data) {
    return kCMIOHardwareUnsupportedOperationError;
}

static OSStatus DeviceStartStream(CMIOHardwarePlugInRef p, CMIODeviceID dev, CMIOStreamID str) {
    if (str == 3) return StreamStart(&gStreamObj);
    return 0;
}

static OSStatus DeviceStopStream(CMIOHardwarePlugInRef p, CMIODeviceID dev, CMIOStreamID str) {
    if (str == 3) return StreamStop(&gStreamObj);
    return 0;
}

static OSStatus StreamCopyBufferQueue_(CMIOHardwarePlugInRef p, CMIOStreamID str, CMIODeviceStreamQueueAlteredProc proc, void *rc, CMSimpleQueueRef *q) {
    if (str == 3) return StreamCopyBufferQueue(&gStreamObj, proc, rc, q);
    return kCMIOHardwareBadObjectError;
}

static OSStatus StreamDeckPlay(CMIOHardwarePlugInRef p, CMIOStreamID s) { if (s==3) return StreamStart(&gStreamObj); return 0; }
static OSStatus StreamDeckStop(CMIOHardwarePlugInRef p, CMIOStreamID s) { if (s==3) return StreamStop(&gStreamObj); return 0; }
static OSStatus StreamDeckJog(CMIOHardwarePlugInRef p, CMIOStreamID s, SInt32 speed) { return 0; }
static OSStatus StreamDeckCueTo(CMIOHardwarePlugInRef p, CMIOStreamID s, Float64 frame, Boolean play) { return 0; }

#import <CoreMediaIO/CMIOHardware.h>

// Forward declare object creation
static CMIOObjectID gDeviceID = 0;
static CMIOObjectID gStreamID = 0;

static void SetPropU32(CMIOObjectID id, CMIOObjectPropertySelector sel, UInt32 v) {
    CMIOObjectPropertyAddress addr = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMaster };
    CMIOObjectSetPropertyData(id, &addr, 0, NULL, sizeof(v), &v);
}

static void SetPropStr(CMIOObjectID id, CMIOObjectPropertySelector sel, CFStringRef s) {
    CMIOObjectPropertyAddress addr = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMaster };
    CMIOObjectSetPropertyData(id, &addr, 0, NULL, sizeof(CFStringRef), &s);
}

static void SetProp(CMIOObjectID id, CMIOObjectPropertySelector sel, UInt32 sz, const void *d) {
    CMIOObjectPropertyAddress addr = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMaster };
    CMIOObjectSetPropertyData(id, &addr, 0, NULL, sz, d);
}

// Initialization
static OSStatus Initialize(CMIOHardwarePlugInRef p) {
    // Init stream resources
    NSDictionary *pix = @{(id)kCVPixelBufferWidthKey:@(kWidth),(id)kCVPixelBufferHeightKey:@(kHeight),(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
    CVPixelBufferPoolCreate(NULL, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolMinimumBufferCountKey:@(3)}, (__bridge CFDictionaryRef)pix, &gStreamObj.pool);
    CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_422YpCbCr8, kWidth, kHeight, NULL, &gStreamObj.formatDesc);
    CMSimpleQueueCreate(NULL, 30, &gStreamObj.queue);
    gStreamObj.width = kWidth; gStreamObj.height = kHeight;
    gStreamObj.running = 0;
    LoadVideo(&gStreamObj);

    // Create device object in CMIO hierarchy
    CMIOObjectID deviceID = 0;
    OSStatus err = CMIOObjectCreate(p, kCMIOObjectSystemObject, kCMIODeviceClassID, &deviceID);
    if (err != noErr) {
        NSLog(@"[VirtualCam] CMIOObjectCreate device failed: %d", err);
        return err;
    }
    gDeviceID = deviceID;

    SetPropStr(deviceID, kCMIOObjectPropertyName, CFSTR(kDeviceName));
    SetPropStr(deviceID, kCMIOObjectPropertyManufacturer, CFSTR(kMfr));
    SetPropStr(deviceID, kCMIOObjectPropertyElementName, CFSTR(kDeviceName));
    SetPropStr(deviceID, kCMIODevicePropertyDeviceUID, CFSTR(kDeviceUID));
    SetPropStr(deviceID, kCMIODevicePropertyModelUID, CFSTR(kModelUID));
    SetPropU32(deviceID, kCMIODevicePropertyDeviceIsAlive, 1);
    SetPropU32(deviceID, kCMIODevicePropertyHogMode, 0);

    // Create stream object
    CMIOObjectID streamID = 0;
    err = CMIOObjectCreate(p, deviceID, kCMIOStreamClassID, &streamID);
    if (err != noErr) {
        NSLog(@"[VirtualCam] CMIOObjectCreate stream failed: %d", err);
        return err;
    }
    gStreamID = streamID;

    SetPropU32(streamID, kCMIOStreamPropertyDirection, 0);
    SetPropU32(streamID, kCMIOStreamPropertyTerminalType, 'vdig');
    SetPropU32(streamID, kCMIOStreamPropertyStartingChannel, 1);
    SetPropU32(streamID, kCMIOStreamPropertyLatency, 0);
    SetProp(streamID, kCMIOStreamPropertyFormatDescription, sizeof(CMFormatDescriptionRef), &gStreamObj.formatDesc);
    Float64 fps = kFPS;
    SetProp(streamID, kCMIOStreamPropertyFrameRate, sizeof(fps), &fps);

    // Add stream to device
    SetProp(deviceID, kCMIODevicePropertyStreams, sizeof(CMIOStreamID), &streamID);

    NSLog(@"[VirtualCam] CMIO initialized: device=%d stream=%d", gDeviceID, gStreamID);
    return noErr;
}

static void Teardown(CMIOHardwarePlugInRef p) {
    if (gStreamObj.running) StreamStop(&gStreamObj);
    if (gStreamObj.queue) CFRelease(gStreamObj.queue);
    if (gStreamObj.pool) CFRelease(gStreamObj.pool);
    if (gStreamObj.formatDesc) CFRelease(gStreamObj.formatDesc);
}

// Name properties
static OSStatus ObjectGetPropertyData(CMIOHardwarePlugInRef p, CMIOObjectID id, const CMIOObjectPropertyAddress *a,
                                       UInt32 qs, const void *q, UInt32 ds, UInt32 *du, void *data) {
    if (a->mSelector == kCMIOObjectPropertyName) {
        CFStringRef s = CFSTR(kDeviceName);
        if (ds >= sizeof(CFStringRef)) { *(CFStringRef *)data = s; if (du) *du = sizeof(CFStringRef); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    if (a->mSelector == kCMIOObjectPropertyManufacturer) {
        CFStringRef s = CFSTR(kMfr);
        if (ds >= sizeof(CFStringRef)) { *(CFStringRef *)data = s; if (du) *du = sizeof(CFStringRef); return 0; }
        return kCMIOHardwareBadPropertySizeError;
    }
    return GetPropertyData(p, id, a, qs, q, ds, du, data);
}

// Build the full interface
static CMIOHardwarePlugInInterface *CreateInterface(void) {
    CMIOHardwarePlugInInterface *iface = calloc(1, sizeof(CMIOHardwarePlugInInterface));
    iface->_reserved = NULL;
    iface->QueryInterface = QueryInterface;
    iface->AddRef = AddRef;
    iface->Release = Release_;
    iface->Initialize = Initialize;
    iface->InitializeWithObjectID = NULL;
    iface->Teardown = (OSStatus(*)(CMIOHardwarePlugInRef))Teardown;
    iface->ObjectShow = NULL;
    iface->ObjectHasProperty = HasProperty;
    iface->ObjectIsPropertySettable = (OSStatus(*)(CMIOHardwarePlugInRef,CMIOObjectID,const CMIOObjectPropertyAddress*,Boolean*))IsPropertySettable;
    iface->ObjectGetPropertyData = ObjectGetPropertyData;
    iface->ObjectSetPropertyData = SetPropertyData;
    iface->DeviceStartStream = DeviceStartStream;
    iface->DeviceStopStream = DeviceStopStream;
    iface->DeviceSuspend = NULL;
    iface->DeviceResume = NULL;
    iface->StreamCopyBufferQueue = StreamCopyBufferQueue_;
    iface->StreamDeckPlay = StreamDeckPlay;
    iface->StreamDeckStop = StreamDeckStop;
    iface->StreamDeckJog = StreamDeckJog;
    iface->StreamDeckCueTo = StreamDeckCueTo;
    return iface;
}

#pragma mark - Factory

void *VirtualCam_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kCMIOHardwarePlugInTypeID)) return NULL;
    if (!gInterface) gInterface = CreateInterface();
    static int dummy = 1;
    return &dummy;
}
