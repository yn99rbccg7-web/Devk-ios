import AVFoundation
import Foundation
import UIKit

/// Keeps the deck's process alive in the background using silent audio — the same
/// mechanism music and navigation apps use. Stated plainly, no theater:
/// - Massively raises jetsam priority: the app survives normal backgrounding.
///   The scanner, agent loop, and Live Activity updates keep running.
/// - The kernel can STILL kill the process under extreme memory pressure.
///   Nothing an app does overrides jetsam. "Unkillable" is not a thing on stock iOS.
/// - The user swiping the app away terminates it. That IS the user's kill switch,
///   working as designed — only the user kills it, nothing else does it casually.
/// Battery trade-off: the CPU stays awake while audio runs. The agent loop should
/// idle politely in background (longer sleeps, no busy polling).
@MainActor final class KeepAlive: @unchecked Sendable {
    static let shared = KeepAlive()

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        // Silent audio source: zeroes every buffer, loops forever.
        let engine = AVAudioEngine()
        let src = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        engine.attach(src)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(src, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
            return
        }
        // Finite-length assertion as a backstop while audio spins up.
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "deck-keepalive") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        engine?.stop()
        engine = nil
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
