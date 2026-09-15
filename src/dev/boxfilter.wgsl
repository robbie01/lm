// The display, scaled into the window with a box filter.
//
// A window pixel and a frame pixel are both squares. A window pixel's colour
// is the average of the frame over its square, each frame pixel counting for
// the area of its overlap with it. So every frame pixel covers the same area
// of the window wherever it lies; a window pixel wholly inside one frame
// pixel is that pixel's colour exactly, and at a whole-number scale every one
// is; and only the window pixels across an edge between frame pixels are a
// mixture, of the pixels either side in proportion.
//
// The average is of light, not of sRGB codes. The frame is decoded as it is
// read, and the result is encoded on the way out: by the target when it is an
// sRGB format, and here when it is not.

struct Fit {
    // Where the frame's top-left corner lies in the target, in target
    // pixels. Always a whole number, so that the edges between frame pixels
    // meet the target's at a whole-number scale.
    origin: vec2f,
    // Target pixels per frame pixel, the same across as down.
    scale: f32,
    // 1 when the target stores values as they are and the encoding is done
    // here.
    encode: f32,
}

@group(0) @binding(0) var<uniform> fit: Fit;
@group(0) @binding(1) var frame: texture_2d<f32>;

// One triangle over the whole target.
@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i & 2u) * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) at: vec4f) -> @location(0) vec4f {
    // The square this pixel covers, in frame pixels. `at` is its centre.
    let lo = (at.xy - 0.5 - fit.origin) / fit.scale;
    let hi = (at.xy + 0.5 - fit.origin) / fit.scale;
    let first = max(vec2i(floor(lo)), vec2i(0));
    let last = min(vec2i(ceil(hi)) - 1, vec2i(textureDimensions(frame)) - 1);
    var sum = vec3f(0.0);
    for (var y = first.y; y <= last.y; y++) {
        let h = min(hi.y, f32(y + 1)) - max(lo.y, f32(y));
        for (var x = first.x; x <= last.x; x++) {
            let w = min(hi.x, f32(x + 1)) - max(lo.x, f32(x));
            // The frame is 0x00RRGGBB words, which lie in memory as B, G, R.
            sum += textureLoad(frame, vec2i(x, y), 0).bgr * (w * h);
        }
    }
    // The square's area is 1 / scale². Where it hangs over the frame's edge
    // the part outside counts as black, the colour of the bars.
    let c = sum * fit.scale * fit.scale;
    return vec4f(select(c, encode(c), fit.encode > 0.5), 1.0);
}

fn encode(c: vec3f) -> vec3f {
    let v = clamp(c, vec3f(0.0), vec3f(1.0));
    return select(1.055 * pow(v, vec3f(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3f(0.0031308));
}
