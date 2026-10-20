#ifndef PIXELLOUPE_JXL_ENCODER_H
#define PIXELLOUPE_JXL_ENCODER_H

#include <stddef.h>
#include <stdint.h>

/// What `pixelloupe_jxl_encode_rgb16` returns.
typedef enum {
    PixelLoupeJXLSuccess = 0,
    /// A size of zero, a missing buffer or a setting out of range.
    PixelLoupeJXLInvalidArgument = 1,
    /// libjxl refused the image or failed while encoding.
    PixelLoupeJXLEncoderError = 2,
    PixelLoupeJXLOutOfMemory = 3,
} PixelLoupeJXLStatus;

/// Encodes one image of interleaved 16-bit RGB samples (`width * height * 3` values, row by row) as a bare JPEG XL
/// codestream, the form a DNG 1.7 tile with compression 52546 holds.
///
/// The samples are linear light with Rec. 2100 (Rec. 2020) primaries and a D65 white, and the codestream says so:
/// Apple's RAW engine reads tile values as the DNG's linear samples, while libjxl uses the color encoding to spend
/// bits where they're visible.
///
/// - `distance`: the Butteraugli distance, 0 (lossless) to 25; Smart Previews use 0.5.
/// - `effort`: 1 (fastest) to 10.
/// - `decodingSpeed`: 0 (smallest) to 4 (fastest to decode).
///
/// On success, `*output` points to the codestream, which the caller frees with `pixelloupe_jxl_free`, and
/// `*outputSize` is its length. Safe to call from several threads at once.
PixelLoupeJXLStatus pixelloupe_jxl_encode_rgb16(const uint16_t *samples, uint32_t width, uint32_t height,
                                                float distance, int effort, int decodingSpeed,
                                                uint8_t **output, size_t *outputSize);

/// Frees a codestream from `pixelloupe_jxl_encode_rgb16`.
void pixelloupe_jxl_free(uint8_t *data);

#endif
