import Foundation
import JXLEncoder

/// Encodes Smart Preview tiles as JPEG XL with the bundled libjxl (`Packages/JXLEncoder`, built by
/// `Scripts/build-libjxl.sh`): 16-bit linear RGB with Rec. 2020 primaries, as the bare codestream a DNG 1.7 tile
/// holds (compression 52546). Only encoding is bundled; Apple's RAW engine decodes the tiles.
///
/// The codestream is tagged linear because the RAW engine reads tile values as the DNG's linear samples whatever
/// transfer function the codestream names; libjxl still spends its bits perceptually.
nonisolated enum JXLTileEncoder {
    /// libjxl's settings. The defaults are the ones Smart Previews use (RAW-85).
    struct Settings: Sendable, Equatable {
        /// Butteraugli distance: 0 is lossless; larger is smaller and lossier.
        var distance: Float = 0.5
        /// 1 (fastest) to 10.
        var effort = 7
        /// 0 (smallest) to 4 (fastest to decode).
        var decodingSpeed = 4
    }

    enum EncodeError: Error, Equatable {
        /// An empty image, the wrong number of samples or a setting out of range.
        case invalidArgument
        case encoderFailed
        case outOfMemory
    }

    /// Encodes `samples`, interleaved RGB (`width * height * 3` values, top row first), as one codestream. Safe to
    /// call from several threads at once, one tile each.
    static func encode(_ samples: [UInt16], width: Int, height: Int, settings: Settings = Settings()) throws -> Data {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              samples.count == width * height * 3 else { throw EncodeError.invalidArgument }
        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        let status = samples.withUnsafeBufferPointer { buffer in
            pixelloupe_jxl_encode_rgb16(
                buffer.baseAddress, UInt32(width), UInt32(height), settings.distance, Int32(settings.effort),
                Int32(settings.decodingSpeed), &output, &size
            )
        }
        switch status {
        case PixelLoupeJXLSuccess:
            guard let output else { throw EncodeError.encoderFailed }
            defer { pixelloupe_jxl_free(output) }
            return Data(bytes: output, count: size)
        case PixelLoupeJXLInvalidArgument: throw EncodeError.invalidArgument
        case PixelLoupeJXLOutOfMemory: throw EncodeError.outOfMemory
        default: throw EncodeError.encoderFailed
        }
    }
}
