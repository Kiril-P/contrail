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
        float width;          // head width, points
        float glow;           // 0...1
        float opacity;        // 0...1
        float pixel;          // size of one device pixel in points
        float highContrast;   // 0 or 1
        float stopCount;
        float style;          // 0 neon, 1 comet, 2 ribbon, 3 dotted, 4 sparks
        float pad1;
        float4 stops[4];
    };

    constant int kStyleComet = 1;
    constant int kStyleRibbon = 2;
    constant int kStyleDotted = 3;

    struct VertexOut {
        float4 position [[position]];
        float2 world;
        float2 p0 [[flat]];
        float2 p1 [[flat]];
        float4 ru [[flat]];   // r0, r1, u0, u1
    };

    // Glow lobes, as multiples of the head width.
    constant float kTightSigma = 0.5;
    constant float kWideSigma = 1.6;
    // Matte mode: extra core radius, rim width and shadow, in points.
    constant float kMatteGrow = 0.5;
    constant float kMatteRim = 1.0;
    constant float kShadowSigma = 2.0;
    constant float kShadowOffset = 1.0;

    // Glow shrinks with the local radius toward the tail.
    static float glowScale(float r, constant Uniforms& u) {
        float headRadius = max(u.width * 0.5, 1e-3);
        return mix(1.0, clamp(r / headRadius, 0.0, 1.0), 0.6);
    }

    static float extentFor(Segment s, constant Uniforms& u) {
        float r = max(s.r0, s.r1);
        if (u.highContrast > 0.5) {
            return r + kMatteGrow + kMatteRim + kShadowOffset + 2.5 * kShadowSigma + 1.0;
        }
        float wideSigma = max(kWideSigma * u.width * glowScale(r, u), 1.0);
        return r + (u.glow > 0.0 ? 2.5 * wideSigma : 0.0) + 2.0;
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

    static float luminance(float3 linearRGB) {
        return dot(linearRGB, float3(0.2126, 0.7152, 0.0722));
    }

    // Scales a color's linear-light luminance down to at most `target`.
    static float3 withLuminanceAtMost(float3 srgb, float target) {
        float3 lin = pow(srgb, 2.2);
        float y = luminance(lin);
        if (y <= target) { return srgb; }
        return pow(lin * (target / y), 1.0 / 2.2);
    }

    static float3 withLuminance(float3 srgb, float target) {
        float3 lin = pow(srgb, 2.2);
        float y = max(luminance(lin), 1e-4);
        return pow(clamp(lin * (target / y), 0.0, 1.0), 1.0 / 2.2);
    }

    // Distance from p to the segment, and the position h (0...1) along it.
    // Each end is a round cap holding its endpoint's radius and age. That
    // only stays seamless because segments are short (TrailGeometry.spacing);
    // extrapolating past the ends instead breaks on slow, short segments.
    static float2 segmentDistance(float2 p, float2 a, float2 b) {
        float2 pa = p - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        return float2(length(pa - ba * h), h);
    }

    fragment float4 trail_fragment(VertexOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(1)]]) {
        float2 dh = segmentDistance(in.world, in.p0, in.p1);
        float d = dh.x;
        float r = mix(in.ru.x, in.ru.y, dh.y);
        float age = clamp(mix(in.ru.z, in.ru.w, dh.y), 0.0, 1.0);
        float aa = u.pixel;
        float3 base = gradientColor(age, u);

        if (u.highContrast > 0.5) {
            // Matte: an opaque body in a darkened hue, a 1 pt rim in the same
            // hue, and a soft shadow. Stays readable on white backgrounds.
            float body = r + kMatteGrow;
            float fade = 1.0 - smoothstep(0.6, 1.0, age);
            float3 fill = withLuminanceAtMost(base, 0.238);   // OKLCH L ~0.62
            float3 rimColor = withLuminance(base, 0.022);     // OKLCH L ~0.28
            float core = 1.0 - smoothstep(body - aa, body + aa, d);
            float rim = 1.0 - smoothstep(body + kMatteRim - aa, body + kMatteRim + aa, d);
            float ds = segmentDistance(in.world + float2(0.0, kShadowOffset), in.p0, in.p1).x;
            float shadow = exp(-pow(max(ds - body, 0.0) / kShadowSigma, 2.0)) * 0.2 * (1.0 - rim);
            float3 color = fill * core + rimColor * (rim - core);
            float alpha = max(rim, shadow);
            return float4(color, alpha) * (fade * u.opacity);
        }

        // Glow: a saturated tube whose inner 40% runs white-hot near the head,
        // inside a tight halo plus a wide, faint one.
        int style = int(u.style + 0.5);
        float fade = style == kStyleComet ? 1.0 - pow(age, 0.6) : 1.0 - pow(age, 2.2);
        float glowStrength = u.glow * (style == kStyleRibbon ? 0.5 : (style == kStyleDotted ? 0.6 : 1.0));
        float core = 1.0 - smoothstep(r - aa, r + aa, d);
        // Keep the hot band at least ~1.5 px wide so it never breaks into dots
        // where the tail gets thin, and let the tail end in pure color.
        float hotInner = 0.3 * r;
        float hotOuter = max(0.7 * r, hotInner + 1.5 * aa);
        float hot = 0.85 * (1.0 - smoothstep(hotInner, hotOuter, d)) * pow(1.0 - age, 1.5);
        if (style == kStyleComet) { hot = min(hot * 1.15, 0.95); }
        float3 coreColor = mix(base, float3(1.0), hot);

        float scale = glowScale(r, u);
        float outside = max(d - r, 0.0);
        float tightSigma = max(kTightSigma * u.width * scale, 0.5);
        float wideSigma = max(kWideSigma * u.width * scale, 1.0);
        float halo = 1.1 * glowStrength * exp(-pow(outside / tightSigma, 2.0))
                   + 0.45 * glowStrength * exp(-pow(outside / wideSigma, 2.0));
        // The halo fades more slowly than the core so the tail keeps a glow.
        // The core is never dimmer than the halo right at its edge; otherwise
        // overlapping capsules would show bright beads at every joint.
        float haloFade = pow(max(fade, 0.0), 0.6);
        float edgeHalo = min(1.55 * glowStrength, 1.0) * haloFade;
        float haloAlpha = (1.0 - core) * min(halo, 1.0) * haloFade;
        float coreAlpha = core * max(fade, edgeHalo);

        if (style == kStyleRibbon) {
            // A flat translucent band with bright edges. The edge is measured
            // from the segment's line, not the capsule, so joints don't light
            // up as arcs.
            float2 ba = in.p1 - in.p0;
            float len = length(ba);
            // Zero-length capsules (dots, the head) have no line, so no edge.
            float lineDistance = len > 1e-3 ? abs(dot(in.world - in.p0, float2(-ba.y, ba.x) / len)) : d;
            float edge = len > 1e-3 ? 1.0 - smoothstep(0.0, 1.0 + aa, abs(r - lineDistance)) : 0.0;
            float body = 0.55 + 0.45 * edge;
            coreAlpha = core * max(fade * body, edgeHalo);
            coreColor = mix(base, float3(1.0), 0.4 * edge * (1.0 - age));
        }

        // Premultiplied output; Opacity scales everything uniformly.
        float3 color = coreColor * coreAlpha + base * haloAlpha;
        return float4(color, coreAlpha + haloAlpha) * u.opacity;
    }

    // MARK: Particles

    struct Particle {
        float2 center;
        float sigma;
        float alpha;
        float4 color;
    };

    struct ParticleOut {
        float4 position [[position]];
        float2 world;
        float2 center [[flat]];
        float2 sigmaAlpha [[flat]];
        float4 color [[flat]];
    };

    vertex ParticleOut particle_vertex(uint vid [[vertex_id]],
                                       uint iid [[instance_id]],
                                       const device Particle* particles [[buffer(0)]],
                                       constant Uniforms& u [[buffer(1)]]) {
        Particle p = particles[iid];
        float extent = 7.5 * p.sigma + 1.0;
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 world = p.center + corner * extent;

        ParticleOut out;
        out.position = float4((world - u.origin) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.world = world;
        out.center = p.center;
        out.sigmaAlpha = float2(p.sigma, p.alpha);
        out.color = p.color;
        return out;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
        float sigma = max(in.sigmaAlpha.x, 0.3);
        float d = length(in.world - in.center);
        // A bright point with a soft halo about three times its size.
        float glow = max(exp(-pow(d / sigma, 2.0)), 0.35 * exp(-pow(d / (3.0 * sigma), 2.0)));
        float hot = 0.8 * exp(-pow(d / (0.6 * sigma), 2.0));
        float alpha = glow * in.sigmaAlpha.y;
        return float4(mix(in.color.rgb, float3(1.0), hot) * alpha, alpha);
    }

    // MARK: Click ripples

    struct Ripple {
        float2 center;
        float radius;
        float width;
        float alpha;
        float fill;
        float2 pad;
        float4 color;
    };

    struct RippleOut {
        float4 position [[position]];
        float2 world;
        float2 center [[flat]];
        float4 shape [[flat]];   // radius, width, alpha, fill
        float4 color [[flat]];
    };

    constant float kRippleTightSigma = 2.0;   // × ring width
    constant float kRippleWideSigma = 6.0;    // × ring width; keep RippleSystem.glowReach in sync
    constant float kMatteRingHalfWidth = 1.5;

    vertex RippleOut ripple_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device Ripple* ripples [[buffer(0)]],
                                   constant Uniforms& u [[buffer(1)]]) {
        Ripple r = ripples[iid];
        float reach = u.highContrast > 0.5
            ? kMatteRingHalfWidth + kMatteRim + kShadowOffset + 2.5 * kShadowSigma
            : (u.glow > 0.0 ? 2.5 * kRippleWideSigma * r.width : 0.0);
        float extent = r.radius + r.width + reach + 2.0;
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 world = r.center + corner * extent;

        RippleOut out;
        out.position = float4((world - u.origin) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.world = world;
        out.center = r.center;
        out.shape = float4(r.radius, r.width, r.alpha, r.fill);
        out.color = r.color;
        return out;
    }

    fragment float4 ripple_fragment(RippleOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]]) {
        float radius = in.shape.x;
        float width = in.shape.y;
        float aa = u.pixel;
        float3 base = in.color.rgb;
        float dist = length(in.world - in.center);
        float disc = (1.0 - smoothstep(radius - aa, radius + aa, dist)) * in.shape.w;

        float4 ring;
        float4 press;
        if (u.highContrast > 0.5) {
            // Matte ring: constant 3 pt body, 1 pt rim in the same hue, soft shadow.
            float3 fill = withLuminanceAtMost(base, 0.238);
            float3 rimColor = withLuminance(base, 0.022);
            float d = abs(dist - radius) - kMatteRingHalfWidth;
            float core = 1.0 - smoothstep(-aa, aa, d);
            float rim = 1.0 - smoothstep(kMatteRim - aa, kMatteRim + aa, d);
            float ds = abs(length(in.world + float2(0.0, kShadowOffset) - in.center) - radius) - kMatteRingHalfWidth;
            float shadow = exp(-pow(max(ds - kMatteRim, 0.0) / kShadowSigma, 2.0)) * 0.2 * (1.0 - rim);
            ring = float4(fill * core + rimColor * (rim - core), max(rim, shadow));
            press = float4(fill * disc, disc);
        } else {
            // Glow ring: a slightly white-hot line with the trail's two-lobe halo.
            float d = abs(dist - radius) - width * 0.5;
            float core = 1.0 - smoothstep(-aa, aa, d);
            float outside = max(d, 0.0);
            float tight = max(kRippleTightSigma * width, 0.5);
            float wide = max(kRippleWideSigma * width, 1.0);
            float halo = 1.1 * u.glow * exp(-pow(outside / tight, 2.0))
                       + 0.45 * u.glow * exp(-pow(outside / wide, 2.0));
            float haloAlpha = (1.0 - core) * min(halo, 1.0);
            float3 coreColor = mix(base, float3(1.0), 0.35);
            ring = float4(coreColor * core + base * haloAlpha, core + haloAlpha);
            press = float4(base * disc, disc);
        }
        // Premultiplied; MAX matches how the pipeline blends overlapping shapes.
        return max(ring, press) * (in.shape.z * u.opacity);
    }
    """
}
