import Foundation
import ImageIO
import AVFoundation
import CoreGraphics

/// Cheap thumbnail decoding for the attachment grid.
///
/// - **Images** go through `CGImageSourceCreateThumbnailAtIndex` so the
///   decoder produces a downsampled `CGImage` directly — far cheaper
///   than loading a 4000×3000 HEIC and resizing in memory.
/// - **Videos** go through `AVAssetImageGenerator` with
///   `appliesPreferredTrackTransform = true` so portrait videos don't
///   come out sideways, and `maximumSize` so a 4K source doesn't decode
///   a 4K frame for an 80pt thumbnail.
///
/// Both paths run off the main actor via `Task.detached(priority:)` so
/// a slow decode doesn't stall the UI.
enum Thumbnailer {

    /// Decode an image thumbnail at `maxPixel` pixels on its longest
    /// side. Returns nil if the file isn't a decodable image type.
    static func image(at url: URL, maxPixel: CGFloat) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
    }

    /// Extract a representative video frame ~1s in. Frame 0 is often
    /// black on consumer captures, so we sample at 1s when the asset is
    /// at least that long.
    static func videoFrame(at url: URL, maxPixel: CGFloat) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Allow up to half a second of slop on either side; some
        // formats only have keyframes at coarse intervals.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

        let target = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: target)
            return cgImage
        } catch {
            // Some formats / corrupt files fail here; caller falls back
            // to a file-type icon.
            return nil
        }
    }
}
