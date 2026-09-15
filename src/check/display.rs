//! The box filter the host window scales the display with, run on this
//! host's GPU and checked against its definition.
//!
//! The reference computes the definition directly, in double precision: a
//! target pixel is the frame's light integrated over the pixel's square,
//! encoded as sRGB. The GPU has to agree to within one code in every channel
//! of every pixel. The frames are noise and black-and-white checks; the
//! scales are below one, one, whole and fractional, with bars across and
//! down; the targets are an sRGB format, which encodes for itself, and a
//! plain one, which the shader encodes for.
//!
//! The pointer is checked against the same pictures: wherever the GPU drew
//! one frame pixel unmixed, a pointer there points at that pixel.

use crate::dev::boxfilter::{Fit, Renderer};

/// Frame size, target size, and what the case stands for.
type Case = ((u32, u32), (u32, u32), &'static str);

const CASES: &[Case] = &[
    ((37, 23), (37, 23), "one to one"),
    ((37, 23), (74, 46), "twice"),
    ((37, 23), (111, 69), "three times"),
    ((37, 23), (100, 100), "fractional, bars above and below"),
    ((37, 23), (200, 61), "fractional, bars either side"),
    ((37, 23), (93, 58), "fractional, bars a pixel apart"),
    ((37, 23), (20, 20), "below one"),
    ((37, 23), (7, 5), "far below one"),
    ((640, 400), (800, 500), "the boot display at 125%"),
    ((1024, 768), (1280, 800), "the workbench in a 1280 by 800 window"),
    ((1024, 768), (2560, 1440), "the workbench across a 2560 by 1440 screen"),
    ((1024, 768), (640, 400), "the workbench in the window it opens in"),
];

pub fn run() -> bool {
    let Some((device, queue, adapter)) = gpu() else {
        println!("display: no graphics adapter, skipped");
        return true;
    };
    let (mut pass, mut fail) = (0, 0);
    for format in [wgpu::TextureFormat::Rgba8UnormSrgb, wgpu::TextureFormat::Rgba8Unorm] {
        let mut renderer = Renderer::new(device.clone(), queue.clone(), format);
        for &((fw, fh), (tw, th), what) in CASES {
            let mut frames = vec![("noise", noise(fw, fh)), ("checks", checks(fw, fh))];
            if pointable((fw, fh), (tw, th)) {
                frames.push(("places", places(fw, fh)));
            }
            for (kind, frame) in frames {
                renderer.upload(&frame, fw, fh);
                let got = render(&renderer, format, tw, th);
                let problem = if kind == "places" {
                    pointer(&got, (fw, fh), (tw, th))
                } else {
                    compare(&got, &reference(&frame, (fw, fh), (tw, th)), tw)
                };
                match problem {
                    None => pass += 1,
                    Some(p) => {
                        fail += 1;
                        println!(
                            "display: {kind}, {fw}x{fh} into {tw}x{th} ({what}), {format:?}: {p}"
                        );
                    }
                }
            }
        }
    }
    println!("display: {pass} passed, {fail} failed, on {adapter}");
    fail == 0
}

fn gpu() -> Option<(wgpu::Device, wgpu::Queue, String)> {
    let instance =
        wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference:
            wgpu::PowerPreference::from_env().unwrap_or(wgpu::PowerPreference::LowPower),
        ..Default::default()
    }))
    .ok()?;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("lmdev display"),
        required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
        ..Default::default()
    }))
    .ok()?;
    let info = adapter.get_info();
    Some((device, queue, format!("{} ({:?})", info.name, info.backend)))
}

/// Draw the renderer's frame into a new `tw` by `th` target of `format`, and
/// read it back as RGBA bytes.
fn render(renderer: &Renderer, format: wgpu::TextureFormat, tw: u32, th: u32) -> Vec<u8> {
    use wgpu::*;
    let (device, queue) = (renderer.device(), renderer.queue());
    let extent = Extent3d { width: tw, height: th, depth_or_array_layers: 1 };
    let target = device.create_texture(&TextureDescriptor {
        label: Some("target"),
        size: extent,
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    renderer.draw(&target.create_view(&TextureViewDescriptor::default()), (tw, th));
    let row = (4 * tw).next_multiple_of(COPY_BYTES_PER_ROW_ALIGNMENT);
    let buffer = device.create_buffer(&BufferDescriptor {
        label: Some("readback"),
        size: row as u64 * th as u64,
        usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor::default());
    encoder.copy_texture_to_buffer(
        target.as_image_copy(),
        TexelCopyBufferInfo {
            buffer: &buffer,
            layout: TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(row),
                rows_per_image: None,
            },
        },
        extent,
    );
    queue.submit([encoder.finish()]);
    buffer.map_async(MapMode::Read, .., |r| r.expect("cannot read the target back"));
    device.poll(PollType::wait_indefinitely()).expect("the GPU did not finish");
    let mapped = buffer.get_mapped_range(..).expect("cannot read the target back");
    let mut out = Vec::with_capacity(4 * tw as usize * th as usize);
    for y in 0..th as usize {
        let start = y * row as usize;
        out.extend_from_slice(&mapped[start..start + 4 * tw as usize]);
    }
    out
}

/// The filter's definition: each target pixel's square, integrated over the
/// frame in light, encoded as sRGB.
fn reference(frame: &[u32], (fw, fh): (u32, u32), (tw, th): (u32, u32)) -> Vec<[u8; 3]> {
    // As large as fits, centred on a whole pixel.
    let s = (tw as f64 / fw as f64).min(th as f64 / fh as f64);
    let ox = ((tw as f64 - fw as f64 * s) / 2.0).max(0.0).floor();
    let oy = ((th as f64 - fh as f64 * s) / 2.0).max(0.0).floor();
    // The frame pixels a target pixel's square overlaps along one axis, and
    // by how much, in frame pixels.
    let overlaps = |t: u32, o: f64, n: u32| -> Vec<(usize, f64)> {
        let (lo, hi) = ((t as f64 - o) / s, (t as f64 + 1.0 - o) / s);
        (0..n)
            .map(|i| (i as usize, hi.min(i as f64 + 1.0) - lo.max(i as f64)))
            .filter(|&(_, w)| w > 0.0)
            .collect()
    };
    let columns: Vec<_> = (0..tw).map(|t| overlaps(t, ox, fw)).collect();
    let light: Vec<f64> = (0..256).map(|c| decode(c as f64 / 255.0)).collect();
    let mut out = Vec::with_capacity(tw as usize * th as usize);
    for ty in 0..th {
        let rows = overlaps(ty, oy, fh);
        for tx in 0..tw as usize {
            let mut sum = [0.0f64; 3];
            for &(fy, wy) in &rows {
                for &(fx, wx) in &columns[tx] {
                    let p = frame[fy * fw as usize + fx];
                    for (c, shift) in [16, 8, 0].into_iter().enumerate() {
                        sum[c] += light[(p >> shift & 255) as usize] * wx * wy;
                    }
                }
            }
            // The square's area in frame pixels is 1 / s².
            out.push(sum.map(|v| (encode(v * s * s) * 255.0).round() as u8));
        }
    }
    out
}

fn decode(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn encode(v: f64) -> f64 {
    let v = v.clamp(0.0, 1.0);
    if v <= 0.0031308 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }
}

/// Where the GPU's picture is more than a code away from the reference.
fn compare(got: &[u8], want: &[[u8; 3]], tw: u32) -> Option<String> {
    let mut off = 0;
    let mut worst = (0, 0, [0u8; 3], [0u8; 3]);
    for (i, w) in want.iter().enumerate() {
        let g = [got[4 * i], got[4 * i + 1], got[4 * i + 2]];
        let d = (0..3).map(|c| g[c].abs_diff(w[c])).max().unwrap();
        if d > 1 {
            off += 1;
            if d > worst.0 {
                worst = (d, i, g, *w);
            }
        }
    }
    (off > 0).then(|| {
        let (d, i, g, w) = worst;
        let (x, y) = (i as u32 % tw, i as u32 / tw);
        format!("{off} pixels off by more than one; worst by {d} at ({x}, {y}), {g:?} where {w:?}")
    })
}

/// Random colours, the same every run.
fn noise(w: u32, h: u32) -> Vec<u32> {
    let mut x = 0x2545_f491_4f6c_dd1du64;
    (0..w * h)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 40) as u32
        })
        .collect()
}

/// Black and white, alternately.
fn checks(w: u32, h: u32) -> Vec<u32> {
    (0..w * h).map(|i| if (i % w + i / w).is_multiple_of(2) { 0 } else { 0xff_ffff }).collect()
}

/// Every pixel says where it is: red six codes a column, green six a row.
/// Blue marks the frame, so the bars are not mistaken for a pixel.
fn places(w: u32, h: u32) -> Vec<u32> {
    (0..w * h).map(|i| ((i % w * 6) << 16) | ((i / w * 6) << 8) | 0x40).collect()
}

/// The pointer is checked where `places` can say where every pixel is, and
/// where the frame is not drawn below its size, where every pixel drawn is a
/// mixture.
fn pointable(frame: (u32, u32), target: (u32, u32)) -> bool {
    frame.0 * 6 < 256 && frame.1 * 6 < 256 && Fit::new(frame, target).scale >= 1.0
}

/// Wherever the GPU drew one pixel of `places` unmixed, a pointer on it has
/// to point at that pixel.
fn pointer(got: &[u8], frame: (u32, u32), (tw, th): (u32, u32)) -> Option<String> {
    let fit = Fit::new(frame, (tw, th));
    let mut seen = 0;
    for ty in 0..th {
        for tx in 0..tw {
            let i = 4 * (ty * tw + tx) as usize;
            let (r, g, b) = (got[i] as u32, got[i + 1] as u32, got[i + 2]);
            if b != 0x40 || r % 6 != 0 || g % 6 != 0 {
                continue;
            }
            seen += 1;
            let at = fit.frame_pixel(frame, tx as f64 + 0.5, ty as f64 + 0.5);
            if at != (r / 6, g / 6) {
                return Some(format!(
                    "a pointer at ({tx}, {ty}) points at frame pixel {at:?}, but {:?} is drawn there",
                    (r / 6, g / 6)
                ));
            }
        }
    }
    (seen == 0).then(|| "no pixel was drawn unmixed".to_string())
}
