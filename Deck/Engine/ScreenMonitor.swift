import Foundation
import Photos
import UIKit

/// Detects screenshots the user takes and ingests them into ScreenMemory.
///
/// Honest limits of stock iOS:
/// - There is no API for an app to silently watch another app's screen.
/// - The screenshot notification fires only while Deck is alive; captures
///   taken while suspended are picked up by checkOnForeground().
/// - Reading the photo library needs the user's Photo Library permission
///   (already declared in Info.plist).
@MainActor
final class ScreenMonitor {
    static let shared = ScreenMonitor()
    private let lastKey = "deck.screenmonitor.last"

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotTaken),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil)
    }

    @objc private func screenshotTaken() {
        // The asset needs a moment to land in the photo library.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.ingestNewScreenshots()
        }
    }

    func checkOnForeground() { ingestNewScreenshots() }

    private func ingestNewScreenshots() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
            return
        case .authorized, .limited:
            break
        default:
            return
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 5
        opts.predicate = NSPredicate(
            format: "mediaSubtype == %d",
            PHAssetMediaSubtype.photoScreenshot.rawValue)
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        let since = UserDefaults.standard.object(forKey: lastKey) as? Date ?? .distantPast
        var newest = since
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate, date > since else { return }
            if date > newest { newest = date }
            ScreenMemory.shared.ingest(asset: asset)
        }
        UserDefaults.standard.set(newest, forKey: lastKey)
    }
}
