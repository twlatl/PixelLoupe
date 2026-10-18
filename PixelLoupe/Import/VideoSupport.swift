import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Video files are shown in the Library but not edited: a poster-frame thumbnail, the length, and
/// playback in the enlarged view. This reads what that needs, without decoding the whole movie.
nonisolated enum VideoSupport {
    struct Info: Sendable, Equatable {
        var duration: Double
        var width: Int
        var height: Int
        var creationDate: Date?
    }

    /// The length, size and creation date of a movie, or `nil` if it can't be read.
    static func read(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds >= 0 else { return nil }
        var width = 0, height = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            // A movie shot upright is stored sideways with a rotation.
            let shown = size.applying(transform)
            width = Int(abs(shown.width).rounded())
            height = Int(abs(shown.height).rounded())
        }
        var created: Date?
        if let item = try? await asset.load(.creationDate) { created = try? await item.load(.dateValue) }
        return Info(duration: duration.seconds, width: width, height: height, creationDate: created)
    }

    /// The frame to show for a movie: the poster frame if one is set, else a moment in (a movie often
    /// starts on black).
    static func posterTime(duration: Double, poster: Double?) -> CMTime {
        let seconds = poster.flatMap { $0 > 0 && $0 < duration ? $0 : nil } ?? min(1, duration * 0.1)
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Writes the thumbnail JPEG for a movie at `destination`.
    static func writeThumbnail(from url: URL, to destination: URL, posterSeconds: Double? = nil, maxPixelSize: Int = ThumbnailStore.maxPixelSize) async throws {
        let image = try await posterImage(from: url, posterSeconds: posterSeconds, maxPixelSize: maxPixelSize)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The frame a movie's thumbnail shows.
    static func posterImage(from url: URL, posterSeconds: Double? = nil, maxPixelSize: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try await generator.image(at: posterTime(duration: duration, poster: posterSeconds)).image
    }

    /// "0:12" or "1:02:03".
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Lightroom's poster frame: `numerator/denominator` as 16 hex digits each (`0000000000000000/0000000000000001`).
    static func lightroomSeconds(_ value: String?) -> Double? {
        guard let value, let slash = value.firstIndex(of: "/"),
              let numerator = UInt64(value[..<slash], radix: 16), let denominator = UInt64(value[value.index(after: slash)...], radix: 16),
              denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
}

nonisolated extension ImageMetadata {
    /// The metadata of a photo or a movie.
    static func readMedia(from url: URL) async -> ImageMetadata? {
        guard SupportedImageTypes.isVideo(url) else { return read(from: url) }
        guard let info = await VideoSupport.read(url) else { return nil }
        var metadata = ImageMetadata()
        metadata.captureDate = info.creationDate
        metadata.pixelWidth = info.width
        metadata.pixelHeight = info.height
        metadata.isVideo = true
        metadata.duration = info.duration
        return metadata
    }
}
