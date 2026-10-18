// Core Image kernels for Photo Merge ▸ HDR (see HDRMerger.swift). Values are scene-linear: each
// exposure as the RAW engine decoded it, and "radiance" is that divided by the exposure's gain
// (how much brighter it is than the reference). Running totals and flags travel in their own images
// rather than in alpha, which Core Image may treat as premultiplied.

#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// Values in this range say something about the scene (outside: noise, or near clipping).
constant float usableLow = 0.03;
constant float usableHigh = 0.9;

float peakOf(float3 rgb) {
    return max(rgb.r, max(rgb.g, rgb.b));
}

bool isUsable(float peak) {
    return peak >= usableLow && peak <= usableHigh;
}

/// How much a value counts: little in deep shadow (noise), nothing near clipping.
float weightOf(float value) {
    float shadow = 0.002 + smoothstep(0.0, 0.15, value);
    float highlight = 1.0 - smoothstep(0.75, 0.95, value);
    return shadow * highlight;
}

/// Adds an exposure's weighted radiance to a running sum. Longer exposures count more (less noise).
float4 hdrAccumulateColor(sample_t sum, sample_t frame, float gain) {
    float weight = weightOf(peakOf(frame.rgb)) * gain;
    return float4(sum.rgb + frame.rgb / gain * weight, 1.0);
}

/// Adds an exposure's weight (red) to a running total.
float4 hdrAccumulateWeight(sample_t total, sample_t frame, float gain) {
    return float4(total.r + weightOf(peakOf(frame.rgb)) * gain, 0.0, 0.0, 1.0);
}

/// The weighted average, or the darkest exposure where every exposure is clipped.
float4 hdrResolve(sample_t sum, sample_t total, sample_t darkest, float darkestGain) {
    return total.r > 0.0 ? float4(sum.rgb / total.r, 1.0) : float4(darkest.rgb / darkestGain, 1.0);
}

/// Deghost: the first usable exposure's radiance, offered in order of preference (the reference
/// first). `found` (red) says whether one was already chosen.
float4 hdrPickColor(sample_t chosen, sample_t found, sample_t frame, float gain) {
    if (found.r > 0.5) { return chosen; }
    return isUsable(peakOf(frame.rgb)) ? float4(frame.rgb / gain, 1.0) : chosen;
}

/// Deghost: whether a usable exposure has been found yet (red).
float4 hdrPickFound(sample_t found, sample_t frame) {
    return float4(max(found.r, isUsable(peakOf(frame.rgb)) ? 1.0 : 0.0), 0.0, 0.0, 1.0);
}

/// Where no exposure is usable: the darkest for a clipped highlight, the brightest for deep shadow.
float4 hdrPickFallback(sample_t chosen, sample_t found, sample_t reference, sample_t darkest, float darkestGain,
                       sample_t brightest, float brightestGain) {
    if (found.r > 0.5) { return chosen; }
    return peakOf(reference.rgb) > usableHigh
        ? float4(darkest.rgb / darkestGain, 1.0)
        : float4(brightest.rgb / brightestGain, 1.0);
}

/// The merge where the mask is off, the single exposure where it's on.
float4 hdrBlendGhost(sample_t merged, sample_t single, sample_t mask) {
    return float4(mix(merged.rgb, single.rgb, clamp(mask.r, 0.0, 1.0)), 1.0);
}

/// An exposure's brightness (log2 of its mean radiance) in red, and whether it's usable in green.
float4 hdrLevel(sample_t frame, float gain) {
    float mean = (frame.r + frame.g + frame.b) / 3.0;
    return float4(log2(max(mean / gain, 1e-6)), isUsable(peakOf(frame.rgb)) ? 1.0 : 0.0, 0.0, 1.0);
}

/// Deghost: the first usable exposure's level, offered in order of preference.
float4 hdrPickLevel(sample_t chosen, sample_t level) {
    return chosen.g > 0.99 ? chosen : (level.g > 0.99 ? level : chosen);
}

/// Marks (red = 1) where a usable exposure disagrees with the chosen one by more than `tolerance`.
float4 hdrMarkGhosts(sample_t marks, sample_t level, sample_t anchor, float tolerance) {
    bool ghost = level.g > 0.99 && anchor.g > 0.99 && abs(level.r - anchor.r) > tolerance;
    return float4(max(marks.r, ghost ? 1.0 : 0.0), 0.0, 0.0, 1.0);
}

/// Log2 of luminance (Rec. 2020), mapped from low…low + range to 0…1: the guide for the base layer.
float4 hdrLogLuminance(sample_t radiance, float low, float range) {
    float luminance = dot(radiance.rgb, float3(0.2627, 0.6780, 0.0593));
    float value = clamp((log2(max(luminance, 1e-6)) - low) / range, 0.0, 1.0);
    return float4(value, value, value, 1.0);
}

/// Tone mapping: the base layer's range is compressed around `anchor` (which lands on `target`) and
/// the local detail is kept. Above `knee` stops over the target, brightness rises only by `shoulder`
/// per stop, so highlights keep their detail instead of running into white. Colors keep their ratios.
float4 hdrToneMap(sample_t radiance, sample_t base, float low, float range, float anchor, float target,
                  float compression, float knee, float shoulder) {
    float3 rgb = max(radiance.rgb, 0.0);
    float luminance = dot(rgb, float3(0.2627, 0.6780, 0.0593));
    float level = log2(max(luminance, 1e-6));
    float baseLevel = base.r * range + low;
    float toned = target + compression * (baseLevel - anchor) + (level - baseLevel);
    float over = toned - (target + knee);
    toned = over > 0.0 ? target + knee + over * shoulder : toned;
    return float4(rgb * exp2(toned - level), 1.0);
}

/// The deghost overlay: red where the mask is on and its eroded copy is off (its outline).
float4 hdrOutline(sample_t image, sample_t mask, sample_t eroded) {
    bool edge = mask.r > 0.5 && eroded.r <= 0.5;
    return edge ? float4(1.0, 0.12, 0.12, 1.0) : image;
}

}
}
