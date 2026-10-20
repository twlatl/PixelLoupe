#include "JXLEncoder.h"

#include <jxl/color_encoding.h>
#include <jxl/encode.h>
#include <stdlib.h>
#include <string.h>

PixelLoupeJXLStatus pixelloupe_jxl_encode_rgb16(const uint16_t *samples, uint32_t width, uint32_t height,
                                                float distance, int effort, int decodingSpeed,
                                                uint8_t **output, size_t *outputSize) {
    if (!samples || !output || !outputSize || width == 0 || height == 0 || !(distance >= 0 && distance <= 25)
        || effort < 1 || effort > 10 || decodingSpeed < 0 || decodingSpeed > 4) {
        return PixelLoupeJXLInvalidArgument;
    }
    *output = NULL;
    *outputSize = 0;

    JxlEncoder *encoder = JxlEncoderCreate(NULL);
    if (!encoder) return PixelLoupeJXLOutOfMemory;
    PixelLoupeJXLStatus status = PixelLoupeJXLEncoderError;
    uint8_t *buffer = NULL;

    // A bare codestream, without the ISO BMFF container: DNG tiles hold just the codestream.
    if (JxlEncoderUseContainer(encoder, JXL_FALSE) != JXL_ENC_SUCCESS) goto done;

    JxlBasicInfo info;
    JxlEncoderInitBasicInfo(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = 16;
    info.exponent_bits_per_sample = 0;
    info.num_color_channels = 3;
    info.alpha_bits = 0;
    // Lossy encoding works in libjxl's perceptual XYB space; lossless keeps the samples as they are.
    info.uses_original_profile = distance == 0 ? JXL_TRUE : JXL_FALSE;
    if (JxlEncoderSetBasicInfo(encoder, &info) != JXL_ENC_SUCCESS) goto done;

    JxlColorEncoding color;
    memset(&color, 0, sizeof color);
    color.color_space = JXL_COLOR_SPACE_RGB;
    color.white_point = JXL_WHITE_POINT_D65;
    color.primaries = JXL_PRIMARIES_2100;
    color.transfer_function = JXL_TRANSFER_FUNCTION_LINEAR;
    color.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL;
    if (JxlEncoderSetColorEncoding(encoder, &color) != JXL_ENC_SUCCESS) goto done;

    JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, NULL);
    if (!settings) goto done;
    if (distance == 0) {
        if (JxlEncoderSetFrameLossless(settings, JXL_TRUE) != JXL_ENC_SUCCESS) goto done;
    } else if (JxlEncoderSetFrameDistance(settings, distance) != JXL_ENC_SUCCESS) {
        goto done;
    }
    if (JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS) goto done;
    if (JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_DECODING_SPEED, decodingSpeed)
        != JXL_ENC_SUCCESS) {
        goto done;
    }

    JxlPixelFormat format = {3, JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0};
    size_t inputSize = (size_t)width * height * 3 * sizeof(uint16_t);
    if (JxlEncoderAddImageFrame(settings, &format, samples, inputSize) != JXL_ENC_SUCCESS) goto done;
    JxlEncoderCloseInput(encoder);

    // Collect the output, growing the buffer as the encoder asks for more room.
    size_t capacity = 64 * 1024, used = 0;
    buffer = malloc(capacity);
    if (!buffer) {
        status = PixelLoupeJXLOutOfMemory;
        goto done;
    }
    for (;;) {
        uint8_t *next = buffer + used;
        size_t available = capacity - used;
        JxlEncoderStatus result = JxlEncoderProcessOutput(encoder, &next, &available);
        used = (size_t)(next - buffer);
        if (result == JXL_ENC_SUCCESS) break;
        if (result != JXL_ENC_NEED_MORE_OUTPUT) goto done;
        uint8_t *larger = realloc(buffer, capacity * 2);
        if (!larger) {
            status = PixelLoupeJXLOutOfMemory;
            goto done;
        }
        buffer = larger;
        capacity *= 2;
    }
    *output = buffer;
    *outputSize = used;
    buffer = NULL;
    status = PixelLoupeJXLSuccess;

done:
    free(buffer);
    JxlEncoderDestroy(encoder);
    return status;
}

void pixelloupe_jxl_free(uint8_t *data) {
    free(data);
}
