import CoreImage
import Foundation
import Metal

/// Runs Lens Corrections' Metal compute shaders inside Core Image, the same way the histogram runs
/// `MPSImageHistogram`. The shaders are compiled at runtime by the system's Metal compiler (once
/// per GPU), so building PixelLoupe needs no extra Metal toolchain.
nonisolated final class LensKernel: CIImageProcessorKernel {
    enum Function: String, Sendable {
        case vignette = "lensVignette"
        case geometry = "lensGeometry"
        case defringe = "lensDefringe"
        case transform = "transformWarp"
    }

    /// Which source region a region of the output needs.
    final class RegionOfInterest: @unchecked Sendable {
        let map: @Sendable (CGRect) -> CGRect
        init(_ map: @escaping @Sendable (CGRect) -> CGRect) { self.map = map }
    }

    private static let functionKey = "function", parametersKey = "parameters", roiKey = "roi"

    /// Applies `function` to `image` with its parameters (see the shaders below for their order).
    static func apply(_ function: Function, to image: CIImage, parameters: [Float], roi: RegionOfInterest? = nil) -> CIImage? {
        // The output gets a transparent one-pixel border, then is cropped to the photo: Core Image
        // samples a processor's output beyond its region by repeating the edge pixels, which
        // otherwise smeared the photo's edges across anything drawn beside it (such as the matte).
        let extent = image.extent
        let bounds: [Float] = [Float(extent.minX), Float(extent.minY), Float(extent.maxX), Float(extent.maxY)]
        return (try? apply(withExtent: extent.insetBy(dx: -1, dy: -1), inputs: [image], arguments: [
            functionKey: function.rawValue,
            parametersKey: bounds + parameters,
            roiKey: roi ?? RegionOfInterest { $0 },
        ]))?.cropped(to: extent)
    }


    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?[roiKey] as? RegionOfInterest)?.map(outputRect) ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let commandBuffer = output.metalCommandBuffer,
              let name = arguments?[functionKey] as? String,
              let parameters = arguments?[parametersKey] as? [Float],
              let pipeline = Pipelines.pipeline(name, device: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        // Where the textures sit in the image, so shaders work in image coordinates.
        let regions: [Float] = [
            Float(output.region.minX), Float(output.region.minY), Float(output.region.height),
            Float(input.region.minX), Float(input.region.minY), Float(input.region.height),
        ]
        let all = regions + parameters
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        all.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Compiled pipelines, per GPU.
    private enum Pipelines {
        nonisolated(unsafe) private static var cache: [UInt64: [String: MTLComputePipelineState]] = [:]
        private static let lock = NSLock()

        static func pipeline(_ name: String, device: MTLDevice) -> MTLComputePipelineState? {
            lock.withLock {
                if let pipelines = cache[device.registryID] { return pipelines[name] }
                var pipelines: [String: MTLComputePipelineState] = [:]
                if let library = try? device.makeLibrary(source: shaderSource, options: nil) {
                    for function in [Function.vignette, .geometry, .defringe, .transform] {
                        if let function = library.makeFunction(name: function.rawValue),
                           let pipeline = try? device.makeComputePipelineState(function: function) {
                            pipelines[function.name] = pipeline
                        }
                    }
                }
                cache[device.registryID] = pipelines
                return pipelines[name]
            }
        }
    }

    /// Parameters start after ten values: the output region's origin (x, y) and height, the input
    /// region's, then the photo's extent (min x, min y, max x, max y), outside which the output is
    /// transparent. Core Image's textures run top to bottom, so rows are flipped.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constexpr sampler pixels(coord::pixel, address::clamp_to_zero, filter::linear);

    /// Image coordinates of an output texel's center.
    static float2 imagePoint(uint2 gid, constant float *p) {
        return float2(p[0] + float(gid.x) + 0.5, p[1] + p[2] - float(gid.y) - 0.5);
    }

    /// The input texture coordinates of an image point.
    static float2 texturePoint(float2 image, constant float *p) {
        return float2(image.x - p[3], p[4] + p[5] - image.y);
    }

    static float4 sampleAt(texture2d<float, access::sample> source, float2 image, constant float *p) {
        return source.sample(pixels, texturePoint(image, p));
    }

    static bool outside(float2 image, constant float *p) {
        return image.x < p[6] || image.y < p[7] || image.x > p[8] || image.y > p[9];
    }

    /// Vignetting: the profile's correction (LensFun's "pa" model, gain = 1 / (1 + k1 r² + k2 r⁴ + k3 r⁶)
    /// with r = 1 at `unit` pixels), scaled by the amount, then the manual corner brightening
    /// (in stops, from `start` of the half diagonal outward).
    /// Parameters: center x, y, unit, k1, k2, k3, amount, half diagonal, manual stops, start.
    kernel void lensVignette(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant float *p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        constant float *q = p + 10;
        float2 image = imagePoint(gid, p);
        if (outside(image, p)) { destination.write(float4(0.0), gid); return; }
        float4 s = sampleAt(source, image, p);
        float2 d = image - float2(q[0], q[1]);
        float gain = 1.0;
        if (q[2] > 0.0) {
            float r2 = dot(d, d) / (q[2] * q[2]);
            float poly = 1.0 + r2 * (q[3] + r2 * (q[4] + r2 * q[5]));
            gain = 1.0 + q[6] * (1.0 / max(poly, 0.05) - 1.0);
        }
        if (q[8] != 0.0) {
            gain *= exp2(q[8] * smoothstep(q[9], 1.0, length(d) / q[7]));
        }
        destination.write(float4(s.rgb * gain, s.a), gid);
    }

    /// Distortion and lateral chromatic aberration: finds where each corrected pixel comes from.
    /// First the manual distortion (rd = ru (1 + k ru²), ru = 1 at the half diagonal), then the
    /// profile's (rd = ru (e ru⁴ + a ru³ + b ru² + c ru + d), ru = 1 at `unit` pixels); red and blue
    /// are then looked up at their own radii (rd = ru (b ru² + c ru + v)). A scale below 1 enlarges
    /// the result (Constrain Crop).
    /// Parameters: center x, y, unit, half diagonal, scale, manual k, a, b, c, d, e,
    /// red b, c, v, blue b, c, v.
    kernel void lensGeometry(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant float *p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        constant float *q = p + 10;
        float2 center = float2(q[0], q[1]);
        if (outside(imagePoint(gid, p), p)) { destination.write(float4(0.0), gid); return; }
        float2 v = (imagePoint(gid, p) - center) * q[4];
        float rn = length(v) / q[3];
        v *= 1.0 + q[5] * rn * rn;
        v /= q[2];
        float r = length(v);
        float f = (((q[10] * r + q[6]) * r + q[7]) * r + q[8]) * r + q[9];
        float2 g = v * f;
        float rg = length(g);
        float fr = (q[11] * rg + q[12]) * rg + q[13];
        float fb = (q[14] * rg + q[15]) * rg + q[16];
        float4 green = sampleAt(source, g * q[2] + center, p);
        float4 red = sampleAt(source, g * fr * q[2] + center, p);
        float4 blue = sampleAt(source, g * fb * q[2] + center, p);
        destination.write(float4(red.r, green.g, blue.b, green.a), gid);
    }

    /// Perspective warp: each output pixel comes from the source point a 3×3 homography gives, found in
    /// pixels from the photo's center. Parameters: center x, y, then the matrix row by row.
    kernel void transformWarp(texture2d<float, access::sample> source [[texture(0)]],
                              texture2d<float, access::write> destination [[texture(1)]],
                              constant float *p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        constant float *q = p + 10;
        float2 image = imagePoint(gid, p);
        if (outside(image, p)) { destination.write(float4(0.0), gid); return; }
        float2 center = float2(q[0], q[1]);
        float2 v = image - center;
        float3 h = float3(q[2] * v.x + q[3] * v.y + q[4],
                          q[5] * v.x + q[6] * v.y + q[7],
                          q[8] * v.x + q[9] * v.y + q[10]);
        if (h.z <= 1e-4) { destination.write(float4(0.0), gid); return; }
        destination.write(sampleAt(source, h.xy / h.z + center, p), gid);
    }

    /// Hue (0…1 around the wheel, 0 = red) and saturation of a color.
    static float2 hueSaturation(float3 c) {
        float high = max(c.r, max(c.g, c.b));
        float low = min(c.r, min(c.g, c.b));
        float chroma = high - low;
        if (chroma <= 1e-5) { return float2(0.0); }
        float h;
        if (high == c.r) { h = (c.g - c.b) / chroma; }
        else if (high == c.g) { h = (c.b - c.r) / chroma + 2.0; }
        else { h = (c.r - c.g) / chroma + 4.0; }
        return float2(fract(h / 6.0), chroma / max(high, 1e-5));
    }

    /// How strongly a hue falls in a slider's range: the slider covers half the wheel starting
    /// at `origin`, and the range (0…1 along the slider) has soft edges.
    static float hueWeight(float hue, float origin, float lower, float upper) {
        float along = fract(hue - origin) / 0.5;
        float soft = 0.04;
        return smoothstep(lower - soft, lower, along) * (1.0 - smoothstep(upper, upper + soft, along));
    }

    /// Defringe: desaturates purple and green fringes along high-contrast edges.
    /// Parameters: radius, purple amount, lower, upper, green amount, lower, upper.
    kernel void lensDefringe(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant float *p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
        constant float *q = p + 10;
        float2 image = imagePoint(gid, p);
        if (outside(image, p)) { destination.write(float4(0.0), gid); return; }
        float4 c = sampleAt(source, image, p);
        if (c.a <= 0.0) { destination.write(c, gid); return; }
        float3 rgb = c.rgb / c.a;
        // Perceptual values for judging hue, saturation and contrast.
        float3 weights = float3(0.2126, 0.7152, 0.0722);
        float3 v = sqrt(max(rgb, 0.0));
        float lum = dot(v, weights);
        float high = lum, low = lum;
        float radius = q[0];
        float2 offsets[4] = { float2(radius, 0.0), float2(-radius, 0.0), float2(0.0, radius), float2(0.0, -radius) };
        for (int i = 0; i < 4; i++) {
            float4 n = sampleAt(source, image + offsets[i], p);
            float l = dot(sqrt(max(n.rgb / max(n.a, 1e-5), 0.0)), weights);
            high = max(high, l);
            low = min(low, l);
        }
        float edge = smoothstep(0.04, 0.2, high - low);
        float2 hs = hueSaturation(v);
        float saturated = smoothstep(0.04, 0.2, hs.y);
        // The purple slider runs from blue-cyan (200°) through purple to orange (20°); green's
        // from orange (30°) through green to blue (210°).
        float strength = q[1] * hueWeight(hs.x, 200.0 / 360.0, q[2], q[3])
                       + q[4] * hueWeight(hs.x, 30.0 / 360.0, q[5], q[6]);
        strength = clamp(strength * edge * saturated, 0.0, 1.0);
        float gray = dot(rgb, weights);
        destination.write(float4(mix(rgb, float3(gray), strength) * c.a, c.a), gid);
    }
    """
}
