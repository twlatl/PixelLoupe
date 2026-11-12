// Core Image kernels for Photo Merge ▸ Focus Stack (see FocusStackMerger.swift). Frames are scene-linear.
// Running totals and maps travel in their own images, with alpha 1: the depth map's state keeps the
// sharpest frame's number in red, its contrast in green, and the lowest contrast any frame had in blue.

#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// A frame moved onto the first one: `row0` and `row1` take a pixel of the result to where it is in the
/// frame. Catmull-Rom (16 reads), because a bilinear read softens every frame that moves by part of a
/// pixel, and sharpness is the point. `gain` matches the frame's brightness to the first frame's.
float4 focusWarp(sampler image, float3 row0, float3 row1, float gain, destination dest) {
    float3 p = float3(dest.coord(), 1.0);
    float2 source = float2(dot(row0, p), dot(row1, p));
    float2 base = floor(source - 0.5) + 0.5;
    float2 f = source - base;
    float2 w0 = ((2.0 - f) * f - 1.0) * f * 0.5;
    float2 w1 = ((3.0 * f - 5.0) * f * f + 2.0) * 0.5;
    float2 w2 = ((4.0 - 3.0 * f) * f + 1.0) * f * 0.5;
    float2 w3 = (f - 1.0) * f * f * 0.5;
    const float wx[4] = { w0.x, w1.x, w2.x, w3.x };
    const float wy[4] = { w0.y, w1.y, w2.y, w3.y };
    float3 sum = float3(0.0);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float2 at = base + float2(float(i) - 1.0, float(j) - 1.0);
            sum += wx[i] * wy[j] * image.sample(image.transform(at)).rgb;
        }
    }
    return float4(max(sum, 0.0) * gain, 1.0);
}

/// A frame's brightness as the eye weighs it (gamma-encoded Rec. 2020 luminance), so detail in the
/// shadows counts as much as detail in the highlights.
float4 focusLuma(sample_t frame) {
    float luminance = dot(max(frame.rgb, 0.0), float3(0.2627, 0.6780, 0.0593));
    return float4(float3(pow(min(luminance, 4.0), 1.0 / 2.2)), 1.0);
}

/// How much fine detail a pixel has: the square of the brightness's Laplacian over its eight
/// neighbors, `step` pixels away. Squared, because what's in focus is not just more contrast but
/// contrast packed into less room: a highlight far out of focus spreads into a disc with a long, fairly
/// crisp rim, which adds up to more plain contrast than the highlight itself has in focus. Scaled so
/// small values keep their precision as half floats.
float4 focusContrast(sampler luma, float step, destination dest) {
    float2 p = dest.coord();
    float center = luma.sample(luma.transform(p)).r;
    float around = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            if (i == 0 && j == 0) { continue; }
            around += luma.sample(luma.transform(p + float2(float(i), float(j)) * step)).r;
        }
    }
    // Not capped: frames that all reached a cap would tie, and the first of them, not the sharpest, would win.
    float laplacian = around - 8.0 * center;
    return float4(laplacian * laplacian * 256.0, 0.0, 0.0, 1.0);
}

/// Fine and coarse detail as one measure: the fine, plus `share` of the coarse.
float4 focusCombine(sample_t fine, sample_t coarse, float share) {
    return float4(fine.r + share * coarse.r, 0.0, 0.0, 1.0);
}

/// The depth map's state after one more frame: this frame's number where it's the sharpest so far,
/// and the lowest contrast seen (what the pixel looks like out of focus).
float4 focusPick(sample_t state, sample_t contrast, float index) {
    float c = contrast.r;
    if (index < 0.5) { return float4(0.0, c, c, 1.0); }
    float lowest = min(state.b, c);
    return c > state.g ? float4(index, c, lowest, 1.0) : float4(state.r, state.g, lowest, 1.0);
}

/// How much say each pixel has in the depth map, ready for filling in: the frame number times its
/// weight (red) and the weight (green). The weight is the pixel's contrast in its sharpest frame, so a
/// crisp edge counts for far more than faint detail. It's nothing where the frames differ by no more
/// than a few times the pixel's own lowest contrast, or `noise` (what a pixel typically has out of
/// focus) if that's more: a flat area, where contrast is only noise and the sharpest frame is chance.
float4 focusWeighted(sample_t state, float noise) {
    float trust = smoothstep(3.0, 8.0, (state.g - state.b) / max(state.b, noise));
    float weight = trust * state.g;
    return float4(state.r * weight, weight, 0.0, 1.0);
}

/// Weighted depth as plain depth (red), with its weight (green): the weighted frame numbers over the
/// weights.
float4 focusDepth(sample_t weighted) {
    return float4(weighted.g > 1e-12 ? weighted.r / weighted.g : 0.0, weighted.g, 0.0, 1.0);
}

/// Filling in the depth map, from the coarsest level up. Each pixel's depth is its own or that of the
/// level below (half the size, read between its pixels), whichever has clearly more weight, and a mix
/// when they're alike; the larger weight goes on to the level above, `reach` of it from below. So strong
/// detail decides for much weaker detail and for the flat areas around it, less the further off it is,
/// detail as strong as its neighbors keeps its own depth, and a flat area far from any detail still
/// gets the depth of the nearest. This is what keeps the inside of a letter from being taken from a
/// frame far out of focus, the only kind with any contrast there.
float4 focusFill(sampler coarser, sampler level, float reach, destination dest) {
    float2 p = dest.coord();
    float2 below = coarser.sample(coarser.transform(p * 0.5)).rg;
    float2 own = level.sample(level.transform(p)).rg;
    float carried = reach * below.g;
    float mine = own.g * own.g;
    float theirs = carried * carried;
    float depth = mine + theirs > 1e-24 ? (mine * own.r / max(own.g, 1e-12) + theirs * below.r) / (mine + theirs) : below.r;
    return float4(depth, max(own.g, carried), 0.0, 1.0);
}

/// The filled-in depth ready for smoothing: weighted by its weight again, so blurring it leaves a crisp
/// edge's depth as it is (a few frames off is visibly soft) and smooths what lies between the edges.
float4 focusSoften(sample_t depth) {
    float weight = depth.g + 1e-9;
    return float4(depth.r * weight, weight, 0.0, 1.0);
}

/// Adds a frame to the result where the depth map chooses it. A depth between two frames takes some
/// of each.
float4 focusAccumulate(sample_t sum, sample_t frame, sample_t depth, float index) {
    float weight = max(0.0, 1.0 - abs(depth.r - index));
    return float4(sum.rgb + frame.rgb * weight, 1.0);
}

/// Weighted Average: a frame's weight at a pixel, from its contrast there as a fraction of the sharpest
/// frame's (the state's green), raised to `power`. `noise` (a little of what a pixel typically has out of
/// focus) is added to both, so where no frame has anything at all they weigh the same and the result is
/// their plain average.
float4 focusShare(sample_t state, sample_t contrast, float power, float noise) {
    float fraction = clamp((contrast.r + noise) / (state.g + noise), 0.0, 1.0);
    return float4(pow(fraction, power), 0.0, 0.0, 1.0);
}

/// Adds a frame to the running sum by its weight.
float4 focusBlend(sample_t sum, sample_t frame, sample_t weight) {
    return float4(sum.rgb + frame.rgb * weight.r, 1.0);
}

/// Adds a frame's weight to the running total.
float4 focusTotal(sample_t total, sample_t weight) {
    return float4(total.r + weight.r, 0.0, 0.0, 1.0);
}

/// The weighted sum over the total weight: the weighted average.
float4 focusResolve(sample_t sum, sample_t total) {
    return float4(sum.rgb / max(total.r, 1e-6), 1.0);
}

/// A depth map (frame numbers in red) as gray: the first frame black, frame `last` white.
float4 focusDepthGray(sample_t depth, float last) {
    float gray = last > 0.0 ? clamp(depth.r / last, 0.0, 1.0) : 0.0;
    return float4(float3(gray), 1.0);
}

}
}
