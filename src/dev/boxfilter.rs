//! Scaling the display into the host window, on wgpu.
//!
//! The frame is drawn as large as the target allows without changing its
//! shape, centred, with black bars where the shapes differ, and resampled
//! with a box filter so that every frame pixel covers the same area of the
//! target (see `boxfilter.wgsl`). At a whole-number scale the frame's pixels
//! are copied; at any other only the target pixels across an edge between
//! two frame pixels are a mixture of them. `lmdev display` checks the result
//! against an exact reference.

/// Where a frame lies in a target: as large as fits without changing its
/// shape and centred, with its top-left corner on a whole target pixel so
/// that at a whole-number scale the frame's pixels line up with the target's.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fit {
    /// The frame's top-left corner, in target pixels.
    pub x: f64,
    pub y: f64,
    /// Target pixels per frame pixel, across and down alike.
    pub scale: f64,
}

impl Fit {
    pub fn new(frame: (u32, u32), target: (u32, u32)) -> Fit {
        let (fw, fh) = (frame.0.max(1) as f64, frame.1.max(1) as f64);
        let (tw, th) = (target.0 as f64, target.1 as f64);
        let scale = (tw / fw).min(th / fh);
        // Rounding can leave a frame that fits a target exactly a hair wider
        // than it, which is no bar at all.
        let x = ((tw - fw * scale) / 2.0).max(0.0).floor();
        let y = ((th - fh * scale) / 2.0).max(0.0).floor();
        Fit { x, y, scale }
    }

    /// What a pointer at (x, y) in the target points at: the frame pixel
    /// under the centre of the target pixel containing it, or over a bar the
    /// nearest frame pixel.
    pub fn frame_pixel(&self, frame: (u32, u32), x: f64, y: f64) -> (u32, u32) {
        if frame.0 == 0 || frame.1 == 0 || self.scale <= 0.0 {
            return (0, 0);
        }
        let fx = ((x.floor() + 0.5 - self.x) / self.scale).floor();
        let fy = ((y.floor() + 0.5 - self.y) / self.scale).floor();
        (fx.clamp(0.0, (frame.0 - 1) as f64) as u32, fy.clamp(0.0, (frame.1 - 1) as f64) as u32)
    }
}

const SHADER: &str = include_str!("boxfilter.wgsl");

/// The frame on the GPU, and what draws it into targets of one format.
pub struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    /// The shader's `Fit`.
    fit: wgpu::Buffer,
    frame: Option<Frame>,
    /// The target stores values as they are, so the shader encodes sRGB.
    encode: bool,
}

struct Frame {
    texture: wgpu::Texture,
    group: wgpu::BindGroup,
    size: (u32, u32),
}

impl Renderer {
    pub fn new(device: wgpu::Device, queue: wgpu::Queue, format: wgpu::TextureFormat) -> Renderer {
        use wgpu::*;
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("boxfilter.wgsl"),
            source: ShaderSource::Wgsl(SHADER.into()),
        });
        let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("frame"),
            entries: &[
                BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: BufferSize::new(16),
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 1,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: false },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
            ],
        });
        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("frame"),
            layout: Some(&device.create_pipeline_layout(&PipelineLayoutDescriptor {
                label: Some("frame"),
                bind_group_layouts: &[Some(&layout)],
                immediate_size: 0,
            })),
            vertex: VertexState {
                module: &shader,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: PrimitiveState::default(),
            depth_stencil: None,
            multisample: MultisampleState::default(),
            fragment: Some(FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(ColorTargetState {
                    format,
                    blend: None,
                    write_mask: ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let fit = device.create_buffer(&BufferDescriptor {
            label: Some("fit"),
            size: 16,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let encode = matches!(
            format,
            TextureFormat::Rgba8Unorm | TextureFormat::Bgra8Unorm | TextureFormat::Rgb10a2Unorm
        );
        Renderer { device, queue, pipeline, layout, fit, frame: None, encode }
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    /// Show `pixels`, a `w` by `h` frame of xRGB words, from now on. A frame
    /// too large for the GPU leaves the last one showing.
    pub fn upload(&mut self, pixels: &[u32], w: u32, h: u32) {
        use wgpu::*;
        let max = self.device.limits().max_texture_dimension_2d;
        if w == 0 || h == 0 || w > max || h > max || pixels.len() < w as usize * h as usize {
            return;
        }
        let extent = Extent3d { width: w, height: h, depth_or_array_layers: 1 };
        if self.frame.as_ref().map(|f| f.size) != Some((w, h)) {
            // sRGB, so that the shader reads light. The words go in as they
            // are, and the shader takes the channels in the order they lie.
            let texture = self.device.create_texture(&TextureDescriptor {
                label: Some("frame"),
                size: extent,
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format: TextureFormat::Rgba8UnormSrgb,
                usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
                view_formats: &[],
            });
            let group = self.device.create_bind_group(&BindGroupDescriptor {
                label: Some("frame"),
                layout: &self.layout,
                entries: &[
                    BindGroupEntry { binding: 0, resource: self.fit.as_entire_binding() },
                    BindGroupEntry {
                        binding: 1,
                        resource: BindingResource::TextureView(
                            &texture.create_view(&TextureViewDescriptor::default()),
                        ),
                    },
                ],
            });
            self.frame = Some(Frame { texture, group, size: (w, h) });
        }
        let frame = self.frame.as_ref().unwrap();
        self.queue.write_texture(
            frame.texture.as_image_copy(),
            bytemuck::cast_slice(&pixels[..w as usize * h as usize]),
            TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * w), rows_per_image: None },
            extent,
        );
    }

    /// Draw the frame into `target`, which is `size` pixels, with black
    /// round it. Black all over until there is a frame.
    pub fn draw(&self, target: &wgpu::TextureView, size: (u32, u32)) {
        use wgpu::*;
        let mut encoder = self.device.create_command_encoder(&CommandEncoderDescriptor::default());
        {
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("frame"),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations { load: LoadOp::Clear(Color::BLACK), store: StoreOp::Store },
                })],
                ..Default::default()
            });
            if let Some(frame) = &self.frame {
                let fit = Fit::new(frame.size, size);
                let mut words = [0u8; 16];
                let fields =
                    [fit.x as f32, fit.y as f32, fit.scale as f32, self.encode as u32 as f32];
                for (i, v) in fields.iter().enumerate() {
                    words[i * 4..i * 4 + 4].copy_from_slice(&v.to_le_bytes());
                }
                self.queue.write_buffer(&self.fit, 0, &words);
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &frame.group, &[]);
                pass.draw(0..3, 0..1);
            }
        }
        self.queue.submit([encoder.finish()]);
    }
}
