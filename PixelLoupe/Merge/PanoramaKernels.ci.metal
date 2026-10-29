// Core Image kernels for Photo Merge ▸ Panorama (see PanoramaMerger.swift). Photos are scene-linear
// and premultiplied: a warped photo's alpha says where it covers the panorama, so blurring it for the
// blend's pyramid fades its color and coverage together. Masks and coverage travel in red, with alpha 1.

#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// The direction a point on the flat panorama shows (see PanoramaProjection.ray(for:)).
float3 panoramaRay(float2 flat, float projection) {
    if (projection < 0.5) {
        return float3(cos(flat.y) * sin(flat.x), sin(flat.y), cos(flat.y) * cos(flat.x));
    }
    if (projection < 1.5) {
        return normalize(float3(sin(flat.x), flat.y, cos(flat.x)));
    }
    return normalize(float3(flat.x, flat.y, 1.0));
}

/// Where in a photo a panorama pixel's direction lands. `r0`…`r2` are the camera's rotation (world to
/// camera) by rows; `camera` is (focal length, half width, half height, height) in the photo's pixels;
/// `pano` is (pixels per flat unit, flat origin x, flat origin y, panorama height). Directions behind
/// the camera land far outside the photo.
float2 panoramaWarp(float3 r0, float3 r1, float3 r2, float4 camera, float4 pano, float projection, destination dest) {
    float2 pixel = float2(dest.coord().x, pano.w - dest.coord().y);
    float3 ray = panoramaRay(pixel / pano.x + pano.yz, projection);
    float3 seen = float3(dot(r0, ray), dot(r1, ray), dot(r2, ray));
    if (seen.z <= 1e-6) { return float2(-1e6, -1e6); }
    float2 offset = seen.xy * (camera.x / seen.z);
    return float2(camera.y + offset.x, camera.w - (camera.z + offset.y));
}

/// The coarsest level of the blend: adds a photo's level where its mask chooses it.
float4 panoramaAddLevel(sample_t total, sample_t level, sample_t mask) {
    return total + level * mask.r;
}

float4 panoramaAdd(sample_t a, sample_t b) {
    return a + b;
}

/// How much of a pixel any photo covers (red), from the photos' alpha.
float4 panoramaCoverage(sample_t coverage, sample_t photo) {
    return float4(max(coverage.r, photo.a), 0.0, 0.0, 1.0);
}

/// The blended panorama made opaque: its color (unpremultiplied) where the photos cover it, `fill`
/// where they don't.
float4 panoramaFinish(sample_t blended, sample_t coverage, float3 fill) {
    float3 color = blended.a > 1e-4 ? max(blended.rgb / blended.a, float3(0.0)) : fill;
    float covered = clamp(coverage.r, 0.0, 1.0);
    return float4(mix(fill, color, covered), 1.0);
}

/// Halves a level of the blend pyramid: each pixel is the 6 × 6 of the finer level's around it, weighted
/// 1 5 10 10 5 1 / 32 each way (a blur of about a pixel, then the 2 × 2 averaged). Pairs of taps are read as one
/// bilinear sample between them, so it's 9 reads. The kernel places its own taps, so it draws the same in any graph
/// (Core Image's blur and scaling transform didn't: the blend changed with what was drawn after it).
float4 panoramaHalve(sampler image, destination dest) {
    float2 center = dest.coord() * 2.0;
    const float offsets[3] = { -5.0 / 3.0, 0.0, 5.0 / 3.0 };
    const float weights[3] = { 6.0, 20.0, 6.0 };
    float4 sum = float4(0.0);
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            sum += weights[i] * weights[j] * image.sample(image.transform(center + float2(offsets[i], offsets[j])));
        }
    }
    return sum / 1024.0;
}

/// One level of the blend: adds a photo's band of detail (its level minus the next level up, enlarged here, bilinear
/// at each pixel's center, rather than by a transform, which Core Image drew differently in different graphs) where
/// its mask (red) chooses it.
float4 panoramaAddBandUp(sampler total, sampler level, sampler coarser, sampler mask, destination dest) {
    float2 p = dest.coord();
    float4 detail = level.sample(level.transform(p)) - coarser.sample(coarser.transform(p * 0.5));
    return total.sample(total.transform(p)) + detail * mask.sample(mask.transform(p)).r;
}

/// Collapsing the blend: a band plus the level above it enlarged (bilinear at each pixel's center).
float4 panoramaAddUp(sampler coarser, sampler band, destination dest) {
    float2 p = dest.coord();
    return coarser.sample(coarser.transform(p * 0.5)) + band.sample(band.transform(p));
}

/// Boundary Warp: each pixel takes the panorama's pixel the warp's map (red, green: fractions of the
/// panorama from its top left; blue: 1 where the map says anything) gives. `size` is (panorama
/// width, height, map width, map height).
float4 panoramaBoundaryWarp(sampler panorama, sampler map, float4 size, destination dest) {
    float2 pixel = dest.coord();
    float2 mapPoint = pixel * float2(size.z / size.x, size.w / size.y);
    float4 entry = map.sample(map.transform(mapPoint));
    if (entry.b < 0.5) { return float4(0.0); }
    float2 source = float2(entry.r * size.x, size.y - entry.g * size.y);
    return panorama.sample(panorama.transform(source));
}

/// Fill Edges at any resolution (see PanoramaFill.Field): each pixel takes what the matches of the solved pixels
/// around it copy there from `color`, offsets scaled to `color`'s resolution, weighted by how well they match and
/// how near they are. `field` holds each solved pixel's match: the copied patch's center (in solved pixels, from the
/// bottom left), its weight, and 1 where there is one. `scale` is (output pixels per solved pixel in x and y, the
/// field's width and height); `origin` is the output's origin.
float4 panoramaFillReconstruct(sampler color, sampler field, float4 scale, float2 origin, destination dest) {
    float2 local = (dest.coord() - origin) / scale.xy;
    float2 base = floor(local);
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 center = base + float2(dx, dy) + 0.5;
            if (center.x < 0.0 || center.y < 0.0 || center.x > scale.z || center.y > scale.w) { continue; }
            float4 entry = field.sample(field.transform(center));
            if (entry.a < 0.5) { continue; }
            float2 offset = local - center;
            float w = entry.b * exp(-dot(offset, offset) / 0.72);
            float2 source = dest.coord() + (entry.rg - center) * scale.xy;
            sum += w * color.sample(color.transform(source)).rgb;
            total += w;
        }
    }
    return float4(total > 0.0 ? sum / total : float3(0.0), 1.0);
}

}
}
