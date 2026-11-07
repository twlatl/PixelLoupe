// Core Image kernel for the post-crop vignette's fitted process (RAW-275; see FittedVignette.swift for where each
// constant comes from). Colors arrive and leave as linear Display P3, whatever the working space.

#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// φ(x): Lightroom's Highlight and Color Priority darken by multiplying exp(φ) by the vignette's factor, per channel
/// of linear ProPhoto RGB. x is the channel's sRGB-encoded value, at 41 even steps from 0 to 1.
constant float vignettePhi[41] = {
    -6.6016, -4.6169, -3.4349, -2.8450, -2.4154, -2.1127, -1.8743, -1.7040, -1.5039, -1.3332, -1.1695,
    -1.0262, -0.8841, -0.7474, -0.6270, -0.5068, -0.4000, -0.2926, -0.1922, -0.0946, 0.0000, 0.0852,
    0.1781, 0.2733, 0.3621, 0.4520, 0.5399, 0.6421, 0.7379, 0.8335, 0.9339, 1.0478, 1.1467, 1.2623,
    1.3800, 1.5022, 1.6371, 1.7885, 1.9487, 2.1470, 2.4376,
};

/// How much Highlights (at 100) holds a channel back from darkening, by its encoded value.
constant float vignetteProtectionAt[8] = { 0.60, 0.65, 0.715, 0.779, 0.842, 0.905, 0.968, 1.0 };
constant float vignetteProtection[8] = { 0.0, 0.01, 0.066, 0.156, 0.277, 0.448, 0.715, 0.82 };

/// The falloff's levels; the kernel gets the radius of each (interpolated for the vignette's Midpoint and Feather).
constant float vignetteLevels[17] = { 0.01, 0.03, 0.06, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.94, 0.97, 0.99 };

float vignetteEncode(float v) {
    float a = fabs(v);
    float e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    return v < 0.0 ? -e : e;
}

float vignetteDecode(float e) {
    float a = fabs(e);
    float v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
    return e < 0.0 ? -v : v;
}

float vignettePhiOf(float e) {
    float t = clamp(e, 0.0, 1.0) * 40.0;
    int i = min(int(t), 39);
    float y = mix(vignettePhi[i], vignettePhi[i + 1], t - float(i));
    if (e > 1.0) y += (e - 1.0) * 40.0 * (vignettePhi[40] - vignettePhi[39]);
    if (e < 0.0) y += e * 40.0 * (vignettePhi[1] - vignettePhi[0]);
    return y;
}

float vignettePhiInverse(float y) {
    if (y <= vignettePhi[0]) return (y - vignettePhi[0]) / (40.0 * (vignettePhi[1] - vignettePhi[0]));
    if (y >= vignettePhi[40]) return 1.0 + (y - vignettePhi[40]) / (40.0 * (vignettePhi[40] - vignettePhi[39]));
    int i = 0;
    for (int j = 1; j < 40; j++) { if (vignettePhi[j] <= y) i = j; }
    return (float(i) + (y - vignettePhi[i]) / (vignettePhi[i + 1] - vignettePhi[i])) / 40.0;
}

float vignetteProtectionOf(float e) {
    if (e <= vignetteProtectionAt[0]) return 0.0;
    for (int i = 1; i < 8; i++) {
        if (e <= vignetteProtectionAt[i]) {
            float f = (e - vignetteProtectionAt[i - 1]) / (vignetteProtectionAt[i] - vignetteProtectionAt[i - 1]);
            return mix(vignetteProtection[i - 1], vignetteProtection[i], f);
        }
    }
    return vignetteProtection[7];
}

/// The falloff v (0 inside … 1 at the edges) at distance r, from the radii of the 17 levels.
float vignetteFalloff(float r, float4 q0, float4 q1, float4 q2, float4 q3, float4 q4) {
    float radii[17] = { q0.x, q0.y, q0.z, q0.w, q1.x, q1.y, q1.z, q1.w, q2.x, q2.y, q2.z, q2.w, q3.x, q3.y, q3.z, q3.w, q4.x };
    if (r <= radii[0]) {
        float slope = (vignetteLevels[1] - vignetteLevels[0]) / max(radii[1] - radii[0], 1e-4);
        return max(0.0, vignetteLevels[0] + slope * (r - radii[0]));
    }
    for (int i = 1; i < 17; i++) {
        if (r <= radii[i]) {
            float f = (r - radii[i - 1]) / max(radii[i] - radii[i - 1], 1e-5);
            return mix(vignetteLevels[i - 1], vignetteLevels[i], f);
        }
    }
    float slope = (vignetteLevels[16] - vignetteLevels[15]) / max(radii[16] - radii[15], 1e-4);
    return min(1.0, vignetteLevels[16] + slope * (r - radii[16]));
}

float3 vignetteToProPhoto(float3 c) {
    return float3(dot(float3(0.631670, 0.213853, 0.154434), c),
                  dot(float3(0.083194, 0.885877, 0.030940), c),
                  dot(float3(-0.001271, 0.050756, 0.950723), c));
}

float3 vignetteFromProPhoto(float3 c) {
    return float3(dot(float3(1.632595, -0.379626, -0.252841), c),
                  dot(float3(-0.153683, 1.166669, -0.013004), c),
                  dot(float3(0.010387, -0.062792, 1.052188), c));
}

/// geometry: center (xy), and the metric's semi-axes in pixels (zw). shape: superellipse exponent (x, 2 for an
/// ellipse), and the metric's scale (y). q0…q4: the falloff's radii. tone: amount (x, 0…1), darkens (y, 1 or 0),
/// style (z: 0 Highlight Priority, 1 Color Priority, 2 Paint Overlay), Highlights (w, 0…1).
float4 vignetteFitted(sample_t pixel, float4 geometry, float4 shape, float4 q0, float4 q1, float4 q2, float4 q3, float4 q4,
                      float4 tone, destination dest) {
    float2 d = (dest.coord() - geometry.xy) / geometry.zw;
    float n = shape.x;
    float r = n == 2.0 ? length(d) : pow(pow(fabs(d.x), n) + pow(fabs(d.y), n), 1.0 / n);
    r *= shape.y;
    float v = vignetteFalloff(r, q0, q1, q2, q3, q4);
    if (v <= 0.0) return pixel;

    float amount = tone.x, style = tone.z, highlights = tone.w;
    float3 c = pixel.rgb;
    if (tone.y > 0.5) {
        // Darkening: the mask m reaches the factor K = (1 − amount)^2.2 in linear light.
        float m = 1.0 - pow(1.0 - v, 2.2);
        float k = max(1.0 - m * (1.0 - pow(1.0 - amount, 2.2)), 1e-4);
        if (style > 1.5) return float4(c * k, pixel.a);
        float3 p = vignetteToProPhoto(c);
        float3 e = float3(vignetteEncode(p.r), vignetteEncode(p.g), vignetteEncode(p.b));
        float3 hold = float3(0.0);
        if (highlights > 0.0) {
            float3 full = float3(vignetteProtectionOf(e.r), vignetteProtectionOf(e.g), vignetteProtectionOf(e.b));
            hold = 1.0 - pow(1.0 - full, float3(highlights));
            // Color Priority holds every channel back by the brightest one's amount, so hues keep.
            if (style > 0.5) hold = float3(max(hold.r, max(hold.g, hold.b)));
        }
        float lk = log(k);
        float3 out = float3(vignettePhiInverse(vignettePhiOf(e.r) + lk * (1.0 - hold.r)),
                            vignettePhiInverse(vignettePhiOf(e.g) + lk * (1.0 - hold.g)),
                            vignettePhiInverse(vignettePhiOf(e.b) + lk * (1.0 - hold.b)));
        p = float3(vignetteDecode(out.r), vignetteDecode(out.g), vignetteDecode(out.b));
        return float4(vignetteFromProPhoto(p), pixel.a);
    }
    // Lightening: Paint Overlay blends toward white in linear light; the others in exp(φ), toward a white of 12.
    if (style > 1.5) {
        float w = pow(amount * v, 2.2);
        return float4(c + w * (1.0 - c), pixel.a);
    }
    float w = 0.95 * pow(amount * v, 2.4);
    float3 p = vignetteToProPhoto(c);
    float3 h = float3(exp(vignettePhiOf(vignetteEncode(p.r))), exp(vignettePhiOf(vignetteEncode(p.g))), exp(vignettePhiOf(vignetteEncode(p.b))));
    h = h + w * (12.0 - h);
    float3 out = float3(vignettePhiInverse(log(h.r)), vignettePhiInverse(log(h.g)), vignettePhiInverse(log(h.b)));
    out = min(out, max(float3(1.0), float3(vignetteEncode(p.r), vignetteEncode(p.g), vignetteEncode(p.b))));
    p = float3(vignetteDecode(out.r), vignetteDecode(out.g), vignetteDecode(out.b));
    return float4(vignetteFromProPhoto(p), pixel.a);
}

}
}
