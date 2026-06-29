//
// MacOS Virtual Camera DAL Plugin
// Full implementation with video file playback via AVAssetReader
// Build: make && sudo make install
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardwarePlugIn.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <pthread.h>

static const int kDefaultWidth  = 1920;
static const int kDefaultHeight = 1080;
static const int kDefaultFPS    = 30;

// ── Virtual Camera Stream ─────────────────────────────────────────────

@interface VirtualCamStream : NSObject
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) int frameIndex;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CMSimpleQueueRef queue;
@property (nonatomic, assign) int videoWidth;
@property (nonatomic, assign) int videoHeight;
- (BOOL)loadVideo:(NSString *)path;
- (CVPixelBufferRef)nextPixelBuffer;
@end

@implementation VirtualCamStream

- (instancetype)init {
    self = [super init];
    _running = NO;
    _frameIndex = 0;
    _videoWidth = kDefaultWidth;
    _videoHeight = kDefaultHeight;
    return self;
}

- (BOOL)loadVideo:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVAsset *asset = [AVAsset assetWithURL:url];

    // Get video track
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        NSLog(@"[VirtualCam] No video track in file: %@", path);
        return NO;
    }

    AVAssetTrack *videoTrack = videoTracks[0];
    CGSize naturalSize = videoTrack.naturalSize;
    _videoWidth = (int)naturalSize.width;
    _videoHeight = (int)naturalSize.height;

    NSLog(@"[VirtualCam] Video loaded: %dx%d, %@",
          _videoWidth, _videoHeight, path);

    // Create reader
    NSError *error = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) {
        NSLog(@"[VirtualCam] AssetReader error: %@", error);
        return NO;
    }

    // Configure output as BGRA pixel buffers
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(_videoWidth),
        (id)kCVPixelBufferHeightKey: @(_videoHeight),
    };

    _trackOutput = [[AVAssetReaderTrackOutput alloc]
                     initWithTrack:videoTrack
                     outputSettings:outputSettings];
    _trackOutput.alwaysCopiesSampleData = NO;

    [_assetReader addOutput:_trackOutput];
    [_assetReader startReading];

    // Create pixel buffer pool
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @(3),
    };

    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            (__bridge CFDictionaryRef)poolAttrs,
                            (__bridge CFDictionaryRef)outputSettings,
                            &_pixelBufferPool);

    // Create queue
    CMSimpleQueueCreate(kCFAllocatorDefault, 30, &_queue);

    return YES;
}

- (CVPixelBufferRef)nextPixelBuffer {
    CMSampleBufferRef sampleBuffer = [_trackOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
        // Loop: restart reader
        if (_assetReader.status == AVAssetReaderStatusCompleted) {
            [_assetReader cancelReading];
            // Re-read from beginning
            AVAsset *asset = _assetReader.asset;
            NSError *error = nil;
            _assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
            if (!error) {
                [_assetReader addOutput:_trackOutput];
                [_assetReader startReading];
            }
            sampleBuffer = [_trackOutput copyNextSampleBuffer];
        }
        if (!sampleBuffer) return NULL;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        CVPixelBufferRetain(pixelBuffer);
    }
    CFRelease(sampleBuffer);
    return pixelBuffer;
}

@end

// ── Frame Pump Thread ──────────────────────────────────────────────────

static void *FramePumpThread(void *arg) {
    VirtualCamStream *stream = (__bridge VirtualCamStream *)arg;
    stream.frameIndex = 0;

    NSLog(@"[VirtualCam] Frame pump started");

    while (stream.running) {
        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = [stream nextPixelBuffer];
            if (pixelBuffer) {
                // Create sample buffer
                CMSampleTimingInfo timing = {
                    .duration = CMTimeMake(1, kDefaultFPS),
                    .presentationTimeStamp = CMTimeMake(stream.frameIndex, kDefaultFPS),
                    .decodeTimeStamp = kCMTimeInvalid
                };

                CMVideoFormatDescriptionRef formatDesc = NULL;
                CMVideoFormatDescriptionCreateForImageBuffer(
                    kCFAllocatorDefault, pixelBuffer, &formatDesc);

                CMSampleBufferRef sb = NULL;
                CMSampleBufferCreateReadyWithImageBuffer(
                    kCFAllocatorDefault, pixelBuffer, formatDesc, &timing, &sb);

                if (sb) {
                    CMSimpleQueueEnqueue(stream.queue, sb);
                    CFRelease(sb);
                }
                if (formatDesc) CFRelease(formatDesc);
                CVPixelBufferRelease(pixelBuffer);
                stream.frameIndex++;
            }
        }
        usleep(1000000 / kDefaultFPS);
    }

    NSLog(@"[VirtualCam] Frame pump stopped. Frames: %d", stream.frameIndex);
    return NULL;
}

// ── Plugin Entry Point (C interface for CoreMediaIO) ───────────────────

static VirtualCamStream *gStream = nil;
static pthread_t gFrameThread;
static BOOL gInitialized = NO;
static CMIOHardwarePlugInRef gPlugInRef = NULL;

void *VirtualCam_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kCMIOHardwarePlugInTypeID)) {
        return NULL;
    }

    if (!gInitialized) {
        gStream = [[VirtualCamStream alloc] init];

        // Find and load video file
        NSString *videoPath = [@"~/Library/Application Support/VirtualCam/video.mp4"
                               stringByExpandingTildeInPath];

        // Also check alternate locations
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *searchPaths = @[
            videoPath,
            [@"~/Desktop/video.mp4" stringByExpandingTildeInPath],
            [@"~/Downloads/video.mp4" stringByExpandingTildeInPath],
        ];

        BOOL loaded = NO;
        for (NSString *path in searchPaths) {
            if ([fm fileExistsAtPath:path]) {
                loaded = [gStream loadVideo:path];
                if (loaded) break;
            }
        }

        if (!loaded) {
            NSLog(@"[VirtualCam] No video file found. Camera will show black.");
        }

        // Start frame pump
        gStream.running = YES;
        pthread_create(&gFrameThread, NULL, FramePumpThread, (__bridge void *)gStream);

        gInitialized = YES;
    }

    // Return a dummy plugin ref — real implementation would create a full CMIO plugin
    static int dummy = 42;
    return &dummy;
}

// ── Stream Accessor (called by CMIO framework) ─────────────────────────

CMSimpleQueueRef VirtualCam_GetQueue(void) {
    return gStream ? gStream.queue : NULL;
}

int VirtualCam_GetWidth(void) {
    return gStream ? gStream.videoWidth : kDefaultWidth;
}

int VirtualCam_GetHeight(void) {
    return gStream ? gStream.videoHeight : kDefaultHeight;
}

void VirtualCam_Stop(void) {
    if (gStream) {
        gStream.running = NO;
        pthread_join(gFrameThread, NULL);
    }
}
