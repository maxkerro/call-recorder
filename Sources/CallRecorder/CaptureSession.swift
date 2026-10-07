import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found. ScreenCaptureKit needs one to capture system audio."
        }
    }
}

/// Captures system audio (Teams, Telemost, Skype, browsers, anything you hear)
/// and the microphone through ScreenCaptureKit (macOS 15+), writing each
/// source to its own temporary CAF file. They are mixed into one MP3 afterwards.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "CallRecorder.audio")

    private(set) var systemURL: URL
    private(set) var micURL: URL
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?

    /// Called on the audio queue for every buffer; used for live transcription.
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    init(tempDir: URL, baseName: String) {
        systemURL = tempDir.appendingPathComponent("\(baseName)-system.caf")
        micURL = tempDir.appendingPathComponent("\(baseName)-mic.caf")
        super.init()
    }

    // Diagnostics: how many buffers of each kind arrived (written on the audio queue, read after stop()).
    private(set) var screenFrames = 0
    private(set) var systemBuffers = 0
    private(set) var micBuffers = 0
    private(set) var convertFailures = 0
    var diagnostics: String {
        "screen frames \(screenFrames), system audio \(systemBuffers), mic \(micBuffers), unreadable \(convertFailures)"
    }

    var hasSystemAudio: Bool { systemFile != nil }
    var hasMicAudio: Bool { micFile != nil }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // We only want audio; keep the (required) video side as cheap as possible.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        // Drain the queue so the last buffers are written before files close.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
        systemFile = nil
        micFile = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio:
            systemBuffers += 1
            guard let buf = Self.pcmBuffer(from: sampleBuffer) else { convertFailures += 1; return }
            write(buf, to: &systemFile, url: systemURL)
            onSystemBuffer?(buf)
        case .microphone:
            micBuffers += 1
            guard let buf = Self.pcmBuffer(from: sampleBuffer) else { convertFailures += 1; return }
            write(buf, to: &micFile, url: micURL)
            onMicBuffer?(buf)
        case .screen:
            screenFrames += 1
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    // MARK: Helpers

    private func write(_ buf: AVAudioPCMBuffer, to file: inout AVAudioFile?, url: URL) {
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url,
                                       settings: buf.format.settings,
                                       commonFormat: buf.format.commonFormat,
                                       interleaved: buf.format.isInterleaved)
            }
            try file?.write(from: buf)
        } catch {
            onError?(error)
        }
    }

    static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var desc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &desc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }
}
