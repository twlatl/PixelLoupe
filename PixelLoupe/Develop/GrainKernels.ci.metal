// Core Image kernels for the fitted film grain (RAW-284, see FittedGrain.swift). The grain is white noise filtered by
// a separable kernel: 1D taps `h` (a Gaussian's response) and `d` (its Laplacian part), up to 11 pixels each side,
// passed as three float4s each (taps 0…11, symmetric).

#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// Near-Gaussian white noise of unit variance from Core Image's random generator: the sum of its four independent
/// uniform channels, centered and scaled. In the red channel.
float4 grainNoise(sample_t random) {
    float n = (random.r + random.g + random.b + random.a - 2.0) * 1.7320508;
    return float4(n, 0.0, 0.0, 1.0);
}

float tap(float4 t0, float4 t1, float4 t2, int i) {
    int k = abs(i);
    float4 t = k < 4 ? t0 : (k < 8 ? t1 : t2);
    int j = k % 4;
    return j == 0 ? t.x : (j == 1 ? t.y : (j == 2 ? t.z : t.w));
}

/// Horizontal pass: red is the noise filtered by `h`, green by `d`.
float4 grainBlurH(sampler noise, float4 h0, float4 h1, float4 h2, float4 d0, float4 d1, float4 d2, destination dest) {
    float2 c = dest.coord();
    float r = 0.0, g = 0.0;
    for (int i = -11; i <= 11; i++) {
        float n = noise.sample(noise.transform(c + float2(float(i), 0.0))).r;
        r += tap(h0, h1, h2, i) * n;
        g += tap(d0, d1, d2, i) * n;
    }
    return float4(r, g, 0.0, 1.0);
}

/// Vertical pass: the grain, `gaussian · h⊗h + laplacian · (h⊗d + d⊗h)`, in the red channel; `lift` (the mean a
/// linear-light downscale adds, times the tone) in green.
float4 grainBlurV(sampler pass, float4 h0, float4 h1, float4 h2, float4 d0, float4 d1, float4 d2, float gaussian, float laplacian,
                  float lift, destination dest) {
    float2 c = dest.coord();
    float hh = 0.0, hd = 0.0;
    for (int i = -11; i <= 11; i++) {
        float4 p = pass.sample(pass.transform(c + float2(0.0, float(i))));
        float h = tap(h0, h1, h2, i), d = tap(d0, d1, d2, i);
        hh += h * p.r;
        hd += d * p.r + h * p.g;
    }
    float grain = gaussian * hh + laplacian * hd;
    return float4(grain, lift, 0.0, 1.0);
}

/// Adds the grain (red) to every channel of `image`, which is gamma-encoded: luminance grain, neutral in color.
/// Within 5% of black or white the grain fades linearly to nothing, as Lightroom's does (so it barely clips there).
float4 grainAdd(sample_t image, sample_t grain) {
    float alpha = max(image.a, 1e-6);
    float3 color = image.rgb / alpha;
    float value = (color.r + color.g + color.b) / 3.0;
    float fade = clamp(min(value, 1.0 - value) / 0.05, 0.0, 1.0);
    float lift = grain.g / max(value, 0.02) * fade;
    return float4((color + grain.r * fade + lift) * image.a, image.a);
}

}
}
