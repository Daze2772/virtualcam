//  VirtualCam.swift — Modern CMIOExtension virtual camera for macOS 12.3+
//  Build:  swiftc -o VirtualCam VirtualCam.swift -framework CoreMediaIO -framework AVFoundation
//  Run:    ./VirtualCam
//  Video:  ~/Library/Application Support/VirtualCam/video.mp4

import CoreMediaIO
import AVFoundation
import Foundation
import CoreVideo

let kDeviceName = "Integrated Camera"
let kWidth  = 1920
let kHeight = 1080
let kFPS    = 30

// ── Video source ──────────────────────────────────────────────────────

class VideoSource {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var asset: AVAsset?

    init() {
        let path = NSString(string: "~/Library/Application Support/VirtualCam/video.mp4").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("[VirtualCam] No video at \(path) — using test pattern")
            return
        }
        asset = AVAsset(url: url)
        guard let track = asset?.tracks(withMediaType: .video).first else { return }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output?.alwaysCopiesSampleData = false
        guard let output = output else { return }
        reader = try? AVAssetReader(asset: asset!)
        reader?.add(output)
        reader?.startReading()
        print("[VirtualCam] Video loaded: \(Int(track.naturalSize.width))x\(Int(track.naturalSize.height))")
    }

    func nextFrame() -> CMSampleBuffer? {
        guard let output = output else { return nil }
        var frame = output.copyNextSampleBuffer()
        if frame == nil && reader?.status == .completed {
            reader?.cancelReading()
            reader = try? AVAssetReader(asset: asset!)
            reader?.add(output)
            reader?.startReading()
            frame = output.copyNextSampleBuffer()
        }
        return frame
    }
}

// ── Stream source — provides frames to the extension ──────────────────

class CamStreamSource: NSObject, CMIOExtensionStreamSource {
    let formats: [CMVideoFormatDescription]
    var sink: CMIOExtensionSink?
    var source: VideoSource
    var timer: DispatchSourceTimer?
    var frameIndex: Int = 0

    init(localizedName: String, streamID: UUID) {
        source = VideoSource()

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_422YpCbCr8,
            width: Int32(kWidth), height: Int32(kHeight),
            extensions: nil, formatDescriptionOut: &formatDesc)
        self.formats = [formatDesc!]

        super.init()
    }

    func startStream() {
        let queue = DispatchQueue(label: "virtualcam.stream")
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .milliseconds(1000 / kFPS))
        timer?.setEventHandler { [weak self] in
            self?.pushFrame()
        }
        timer?.resume()
        print("[VirtualCam] Stream started")
    }

    func stopStream() {
        timer?.cancel()
        timer = nil
        print("[VirtualCam] Stream stopped")
    }

    func pushFrame() {
        guard let sink = sink else { return }
        let pts = CMTimeMake(value: Int64(frameIndex), timescale: Int32(kFPS))
        frameIndex += 1

        var sb: CMSampleBuffer?

        if let frame = source.nextFrame() {
            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(frame, at: 0, timingInfoOut: &timing)
            timing.presentationTimeStamp = pts
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: frame,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &sb)
        }

        if sb == nil {
            // Test pattern
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let buf = pixelBuffer else { return }
            CVPixelBufferLockBaseAddress(buf, [])
            let w = CVPixelBufferGetWidth(buf)
            let h = CVPixelBufferGetHeight(buf)
            let rb = CVPixelBufferGetBytesPerRow(buf)
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bx = (frameIndex * 4) % w
            for y in 0..<h {
                let row = base + y * rb
                for x in 0..<w {
                    let i = x * 4
                    if x >= bx && x < bx + 200 {
                        row[i] = 233; row[i+1] = 69; row[i+2] = 96; row[i+3] = 255
                    } else {
                        row[i] = 26; row[i+1] = 26; row[i+2] = 40; row[i+3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            var timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: Int32(kFPS)),
                                            presentationTimeStamp: pts,
                                            decodeTimeStamp: .invalid)
            var formatDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buf, formatDescriptionOut: &formatDesc)
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buf,
                                                     formatDescription: formatDesc!, sampleTiming: &timing, sampleBufferOut: &sb)
        }

        if let sample = sb {
            sink.streamSender.send(sample, discontinuity: [], hostTimeInNanos: UInt64(CACurrentMediaTime() * 1_000_000_000))
        }
    }

    // CMIOExtensionStreamSource protocol
    var streamProperties: CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties()
        props.activeFormatIndex = 0
        props.frameDuration = CMTimeMake(value: 1, timescale: Int32(kFPS))
        return props
    }

    var authorizedToStartStream: Bool { true }

    func authorizationCompletion() {}

    func setStreamProperties(_ props: CMIOExtensionStreamProperties) -> CMIOExtensionStreamProperties { props }
}

// ── Device source ──────────────────────────────────────────────────────

class CamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    let streams: [CamStreamSource]

    init(localizedName: String) {
        let streamID = UUID()
        self.streams = [CamStreamSource(localizedName: localizedName, streamID: streamID)]
        super.init()
    }

    var deviceProperties: CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties()
        props.setPropertyState(CMIOExtensionProperty(state: "VirtualCam Inc."),
                               forProperty: .providerManufacturer)
        return props
    }

    func setDeviceProperties(_ props: CMIOExtensionDeviceProperties) -> CMIOExtensionDeviceProperties { props }
}

// ── Provider ──────────────────────────────────────────────────────────

class CamProvider: CMIOExtensionProvider {
    override init() {
        super.init()
        print("[VirtualCam] Provider initialized")
    }
}

// ── Main ──────────────────────────────────────────────────────────────

let provider = CamProvider()
let deviceSource = CamDeviceSource(localizedName: kDeviceName)

do {
    let deviceID = UUID()
    try provider.addDevice(deviceID: deviceID,
                          localizedName: kDeviceName,
                          deviceSource: deviceSource,
                          streamSources: deviceSource.streams)
    print("[VirtualCam] Device registered: '\(kDeviceName)'")
    print("[VirtualCam] Running... Press Ctrl+C to stop")

    // Keep running
    RunLoop.main.run()
} catch {
    print("[VirtualCam] Failed to add device: \(error)")
    exit(1)
}
