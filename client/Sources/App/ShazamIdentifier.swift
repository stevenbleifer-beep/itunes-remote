import Foundation
import AVFoundation
import ShazamKit

/// Controls ▸ Identify What's Playing…: listens to the Mac's microphone
/// for a few seconds and asks Shazam what it heard. The answer feeds the
/// same places the catalogue does — find it in the library, or on the
/// Apple Music side play it or add it.
///
/// ShazamKit signs its own requests for this app (the identifier needs
/// the ShazamKit service, like MusicKit). The microphone needs a one-time
/// permission. Nothing is recorded: the audio becomes a signature in
/// memory and only that goes to Shazam.
@MainActor
final class ShazamIdentifier: NSObject, SHSessionDelegate {
    struct Match {
        let title: String
        let artist: String
        let appleMusicID: String?
        let artworkURL: URL?
        let webURL: URL?
    }

    private var session: SHSession?
    private var engine: AVAudioEngine?
    private var completion: ((Result<Match?, Error>) -> Void)?
    private var timeout: Timer?

    /// Listens for up to `seconds` and calls back once: a match, nil for
    /// nothing recognised, or an error.
    func listen(seconds: Double = 12, then done: @escaping (Result<Match?, Error>) -> Void) {
        stop()
        completion = done
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            Task { @MainActor in
                guard let self = self else { return }
                guard ok else {
                    self.finish(.failure(ShazamError("The microphone was not allowed. System Settings ▸ Privacy & Security ▸ Microphone.")))
                    return
                }
                self.startListening(seconds: seconds)
            }
        }
    }

    private func startListening(seconds: Double) {
        let session = SHSession()
        session.delegate = self
        self.session = session
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            finish(.failure(ShazamError("No microphone is available.")))
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            session.matchStreamingBuffer(buffer, at: when)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            finish(.failure(error))
            return
        }
        timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(.success(nil)) }
        }
    }

    /// The same question asked of an audio file, for testing without a
    /// microphone (`--shazam-file PATH`).
    func identify(file url: URL, then done: @escaping (Result<Match?, Error>) -> Void) {
        stop()
        completion = done
        do {
            let audio = try AVAudioFile(forReading: url)
            let generator = SHSignatureGenerator()
            let format = audio.processingFormat
            // Twelve seconds from the middle: enough for a signature, and
            // past any silence at the start.
            let start = max(0, audio.length / 2 - AVAudioFramePosition(format.sampleRate * 6))
            audio.framePosition = start
            let frames = AVAudioFrameCount(format.sampleRate * 12)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw ShazamError("Could not read that file.")
            }
            try audio.read(into: buffer, frameCount: frames)
            try generator.append(buffer, at: nil)
            let session = SHSession()
            session.delegate = self
            self.session = session
            session.match(generator.signature())
        } catch {
            finish(.failure(error))
        }
    }

    func stop() {
        timeout?.invalidate()
        timeout = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        session = nil
    }

    private func finish(_ result: Result<Match?, Error>) {
        let done = completion
        completion = nil
        stop()
        done?(result)
    }

    // MARK: SHSessionDelegate

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        let item = match.mediaItems.first
        let found = item.map {
            Match(title: $0.title ?? "Unknown", artist: $0.artist ?? "", appleMusicID: $0.appleMusicID,
                  artworkURL: $0.artworkURL, webURL: $0.webURL)
        }
        Task { @MainActor in self.finish(.success(found)) }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // While listening, silence between attempts is normal; the timer
        // decides when to give up. For a file there is one attempt.
        Task { @MainActor in
            if self.engine == nil { self.finish(error.map { .failure($0) } ?? .success(nil)) }
        }
    }
}

struct ShazamError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
