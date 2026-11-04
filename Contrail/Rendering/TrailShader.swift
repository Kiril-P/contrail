// The Metal shader is compiled at runtime from this source so contributors and
// CI don't need Xcode's separately-downloaded Metal toolchain.
//
// Each trail segment is drawn as one instanced quad. The fragment shader
// computes the exact distance to the segment ("capsule"), so the core, the
// anti-aliased edge and the glow all come out of a single pass with no blur.
// Segments are blended with MAX, so overlapping capsules merge into one
// continuous ribbon instead of stacking up brighter at every joint.

enum TrailShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Segment {
        float2 p0;
        float2 p1;
        float r0;
        float r1;
        float u0;
        float u1;
    };

    struct Uniforms {
        float2 viewSize;      // points
        float2 origin;        // window origin in global points
        float glowRadius;     // points
        float glowIntensity;  // 0...1
        float opacity;        // 0...1
        float pixel;          // size of one device pixel in points
        float highContrast;   // 0 or 1
        float stopCount;
        float pad0;
        float pad1;
        float4 stops[4];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 world;
        float2 p0 [[flat]];
        float2 p1 [[flat]];
        float4 ru [[flat]];   // r0, r1, u0, u1
    };

    static float extentFor(Segment s, constant Uniforms& u) {
        float r = max(s.r0, s.r1);
        float outline = u.highContrast > 0.5 ? max(1.5, r * 0.3) + 6.0 : 0.0;
        return r + max(u.glowRadius * (1.0 - u.highContrast), 0.0) + outline + 2.0;
    }

    vertex VertexOut trail_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device Segment* segments [[buffer(0)]],
                                  constant Uniforms& u [[buffer(1)]]) {
        Segment s = segments[iid];
        float extent = extentFor(s, u);
        float2 d = s.p1 - s.p0;
        float len = length(d);
        float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
        float2 normal = float2(-dir.y, dir.x);

        float along = (vid & 1) ? (len + extent) : -extent;
        float side = (vid & 2) ? extent : -extent;
        float2 world = s.p0 + dir * along + normal * side;
        float2 local = world - u.origin;

        VertexOut out;
        out.position = float4(local / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.world = world;
        out.p0 = s.p0;
        out.p1 = s.p1;
        out.ru = float4(s.r0, s.r1, s.u0, s.u1);
        return out;
    }

    static float3 gradientColor(float t, constant Uniforms& u) {
        int count = int(u.stopCount);
        if (count <= 1) { return u.stops[0].rgb; }
        float position = clamp(t, 0.0, 1.0) * float(count - 1);
        int index = min(int(position), count - 2);
        return mix(u.stops[index].rgb, u.stops[index + 1].rgb, position - float(index));
    }

    fragment float4 trail_fragment(VertexOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(1)]]) {
        float2 pa = in.world - in.p0;
        float2 ba = in.p1 - in.p0;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        float d = length(pa - ba * h);
        float r = mix(in.ru.x, in.ru.y, h);
        float t = mix(in.ru.z, in.ru.w, h);

        // Head is fully opaque; the tail eases out to transparent.
        float fade = u.opacity * pow(1.0 - clamp(t, 0.0, 1.0), 1.4);
        float aa = u.pixel;
        float3 base = gradientColor(t, u);

        if (u.highContrast > 0.5) {
            // Matte: opaque colored core, dark outline, soft shadow. Readable on white.
            float outline = max(1.5, r * 0.3);
            float core = 1.0 - smoothstep(r - aa, r + aa, d);
            float rim = 1.0 - smoothstep(r + outline - aa, r + outline + aa, d);
            float shadow = exp(-pow(max(d - r - outline, 0.0) / 3.0, 2.0)) * 0.35 * (1.0 - rim);
            float3 rimColor = base * 0.18;
            float3 color = base * core + rimColor * (rim - core);
            float alpha = max(rim, shadow);
            return float4(color * fade, alpha * fade);
        }

        // Glow: anti-aliased core with a white-hot center, plus a Gaussian halo.
        float core = 1.0 - smoothstep(r - aa, r + aa, d);
        float sigma = max(u.glowRadius * 0.5, 1e-3);
        float glow = u.glowRadius > 0.0
            ? exp(-pow(max(d - r, 0.0) / sigma, 2.0)) * u.glowIntensity
            : 0.0;
        float hot = core * pow(clamp(1.0 - d / max(r, 1e-3), 0.0, 1.0), 1.5) * 0.8;
        float3 color = mix(base, float3(1.0), hot);
        float alpha = max(core, glow);
        return float4(color * alpha * fade, alpha * fade);
    }
    """
}
