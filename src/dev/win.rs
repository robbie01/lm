//! The host window, on winit, with the display drawn into it by `boxfilter`.
//!
//! winit wants the main thread, so the window has it and the machine runs on
//! a thread of its own. Between them is one lock over a little shared state:
//! the machine hands finished frames over and takes the input that has
//! arrived, and wakes the window's thread when there is a frame to draw. The
//! window draws at the display's pace whatever the machine is doing, and
//! dragging or resizing the window does not stop the machine.
//!
//! The machine asks for its window once it is ready to run, through the
//! `Host` it is handed, so a machine that cannot start never shows one.
//! Everything else sees the `Present` trait, and a headless run never starts
//! an event loop at all.

use crate::dev::boxfilter::{Fit, Renderer};
use crate::dev::gfx::Present;
use crate::dev::input::*;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy, OwnedDisplayHandle};
use winit::keyboard::{Key, KeyCode, ModifiersState, NamedKey, PhysicalKey};
use winit::platform::modifier_supplement::KeyEventExtModifierSupplement;
use winit::window::{Window, WindowId};

/// How far a trackpad moves, in logical pixels, for one step of the wheel.
const WHEEL_STEP: f64 = 20.0;

/// Run `machine` with the window's event loop on this thread and the machine
/// on another, handing it the `Host` it opens its window through. Answers
/// what `machine` answers.
///
/// Where there can be no event loop the machine runs on this thread, and
/// opening its window says why there is none.
pub fn run<F>(machine: F) -> i32
where
    F: FnOnce(Host) -> i32 + Send,
{
    let event_loop = match EventLoop::<Wake>::with_user_event().build() {
        Ok(l) => l,
        Err(e) => return machine(Host { link: Err(e.to_string()) }),
    };
    let shared = Arc::new(Shared::default());
    let proxy = event_loop.create_proxy();
    let mut app = App::new(shared.clone(), event_loop.owned_display_handle());
    std::thread::scope(|s| {
        let host = Host { link: Ok((proxy.clone(), shared.clone())) };
        let worker = std::thread::Builder::new()
            .name("machine".into())
            .spawn_scoped(s, move || {
                // However the machine stops, the event loop hears of it.
                let _stopped = Stopped(proxy);
                machine(host)
            })
            .expect("cannot start the machine's thread");
        if let Err(e) = event_loop.run_app(&mut app) {
            eprintln!("lm: the window's event loop failed: {e}");
        }
        // A machine still running stops at its next frame.
        shared.lock().closed = true;
        drop(app);
        match worker.join() {
            Ok(code) => code,
            Err(panic) => std::panic::resume_unwind(panic),
        }
    })
}

/// How the machine's thread reaches the window's.
pub struct Host {
    link: Result<(EventLoopProxy<Wake>, Arc<Shared>), String>,
}

impl Host {
    /// Open a window titled `title` onto a `w` by `h` display, at `scale`
    /// times the display's size. Waits until it is open or has failed to.
    pub fn open(self, title: &str, w: u32, h: u32, scale: u32) -> Result<HostWindow, String> {
        let (proxy, shared) = self.link?;
        let gone = || "the event loop has stopped".to_string();
        let (reply, answer) = mpsc::channel();
        proxy
            .send_event(Wake::Open { title: title.to_string(), frame: (w, h), scale, reply })
            .map_err(|_| gone())?;
        answer.recv().map_err(|_| gone())??;
        Ok(HostWindow { proxy, shared })
    }
}

/// The machine's end of an open window.
pub struct HostWindow {
    proxy: EventLoopProxy<Wake>,
    shared: Arc<Shared>,
}

impl Present for HostWindow {
    fn show(&mut self, frame: &mut Vec<u32>, w: usize, h: usize) -> bool {
        let mut s = self.shared.lock();
        if s.closed {
            return false;
        }
        // The window takes the newest frame when it next draws. A frame it
        // has not taken by then is dropped, and its buffer comes back here.
        std::mem::swap(&mut s.frame, frame);
        let resized =
            std::mem::replace(&mut s.frame_size, (w as u32, h as u32)) != (w as u32, h as u32);
        let waiting = std::mem::replace(&mut s.fresh, true);
        drop(s);
        // A window with a frame waiting has been woken for it already, unless
        // the display has changed size since, which moves the pointer in it.
        if !waiting || resized {
            let _ = self.proxy.send_event(Wake::Frame);
        }
        true
    }

    fn size(&self) -> (u32, u32) {
        self.shared.lock().size
    }

    fn pump(&mut self, ev: &mut Input) {
        let mut s = self.shared.lock();
        for w in s.events.drain(..) {
            ev.push(w);
        }
        (ev.mx, ev.my) = s.pointer;
        ev.buttons = s.buttons;
        ev.mods = s.mods;
    }
}

/// What the machine's thread tells the window's.
enum Wake {
    /// Open the window, and reply whether it opened.
    Open { title: String, frame: (u32, u32), scale: u32, reply: mpsc::Sender<Result<(), String>> },
    /// There is a frame to draw.
    Frame,
    /// The machine has stopped.
    Stopped,
}

/// Tells the event loop the machine has stopped, when it is dropped.
struct Stopped(EventLoopProxy<Wake>);

impl Drop for Stopped {
    fn drop(&mut self) {
        let _ = self.0.send_event(Wake::Stopped);
    }
}

/// What the two threads share, under one lock.
#[derive(Default)]
struct Shared(Mutex<State>);

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        // Nothing done under the lock leaves the state half changed, so a
        // thread that panicked holding it has not spoilt it.
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[derive(Default)]
struct State {
    /// The newest frame the machine has handed over, its size, and whether
    /// the window has yet to take it.
    frame: Vec<u32>,
    frame_size: (u32, u32),
    fresh: bool,
    /// Events the machine has yet to take, packed as the input chip queues
    /// them.
    events: VecDeque<u32>,
    /// Where the pointer is in the frame, and the buttons and modifiers held.
    pointer: (u32, u32),
    buttons: u32,
    mods: u32,
    /// The window's size in pixels.
    size: (u32, u32),
    /// The window has been closed.
    closed: bool,
}

impl State {
    /// Queue an event for the machine. A pointer move waiting at the back of
    /// the queue is replaced rather than followed, so the machine hears where
    /// the pointer went between one other event and the next, not every step
    /// it took on the way.
    fn post(&mut self, w: u32) {
        let moved = |w: u32| word_kind(w) == EV_MOUSEMOVE;
        match self.events.back_mut() {
            Some(last) if moved(*last) && moved(w) => *last = w,
            _ => {
                if self.events.len() >= QUEUE_MAX {
                    self.events.pop_front();
                }
                self.events.push_back(w);
            }
        }
    }
}

/// The window's thread.
struct App {
    shared: Arc<Shared>,
    display: OwnedDisplayHandle,
    /// The event loop has started, and windows can be made.
    started: bool,
    /// A request to open the window that came before that.
    early: Option<Wake>,
    win: Option<Win>,
    /// The frame last taken from the machine, and the size of the machine's
    /// display, which is what the pointer is placed in.
    pixels: Vec<u32>,
    frame: (u32, u32),
    /// The keys held, each with the code and ascii it went down with.
    keys: Vec<(PhysicalKey, u32, u32)>,
    buttons: u32,
    mods: ModifiersState,
    /// Where the pointer was last over the window, and where that is in the
    /// frame.
    cursor: Option<PhysicalPosition<f64>>,
    pointer: (u32, u32),
    /// Wheel travel short of a whole step.
    wheel: f64,
}

/// A window, and what draws into it.
struct Win {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    renderer: Renderer,
}

impl Win {
    /// Make the surface `size`, which is not zero.
    fn reconfigure(&mut self, size: PhysicalSize<u32>) {
        self.config.width = size.width;
        self.config.height = size.height;
        self.surface.configure(self.renderer.device(), &self.config);
    }
}

impl App {
    fn new(shared: Arc<Shared>, display: OwnedDisplayHandle) -> App {
        App {
            shared,
            display,
            started: false,
            early: None,
            win: None,
            pixels: Vec::new(),
            frame: (0, 0),
            keys: Vec::new(),
            buttons: 0,
            mods: ModifiersState::empty(),
            cursor: None,
            pointer: (0, 0),
            wheel: 0.0,
        }
    }

    fn open(
        &mut self,
        event_loop: &ActiveEventLoop,
        title: &str,
        frame: (u32, u32),
        scale: u32,
    ) -> Result<(), String> {
        let attributes = Window::default_attributes()
            .with_title(title)
            .with_inner_size(LogicalSize::new(frame.0 * scale, frame.1 * scale));
        let window = Arc::new(event_loop.create_window(attributes).map_err(|e| e.to_string())?);
        let instance =
            wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle_from_env(
                Box::new(self.display.clone()),
            ));
        let surface = instance.create_surface(window.clone()).map_err(|e| e.to_string())?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference:
                wgpu::PowerPreference::from_env().unwrap_or(wgpu::PowerPreference::LowPower),
            compatible_surface: Some(&surface),
            ..Default::default()
        }))
        .map_err(|e| e.to_string())?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("lm"),
            // The adapter's own largest texture, for a window the size of
            // a large screen.
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
            ..Default::default()
        }))
        .map_err(|e| e.to_string())?;
        // An sRGB format encodes what is drawn into it; for any other the
        // shader does.
        let formats = surface.get_capabilities(&adapter).formats;
        let format = formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .or(formats.first().copied())
            .ok_or_else(|| "the window cannot be drawn into".to_string())?;
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            desired_maximum_frame_latency: 1,
            alpha_mode: wgpu::CompositeAlphaMode::Auto,
            view_formats: vec![],
        };
        // A window that cannot be drawn into shows it here, as an error the
        // device would otherwise panic with: say so, and the machine runs
        // headless.
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        surface.configure(&device, &config);
        let renderer = Renderer::new(device.clone(), queue, format);
        let failed = pollster::block_on(internal.pop());
        if let Some(e) = failed.or(pollster::block_on(validation.pop())) {
            return Err(format!("the window cannot be drawn into: {}", one_line(&e)));
        }
        // From here on the machine matters more than the picture of it: an
        // error drawing is reported, once, and the machine carries on.
        let reported = AtomicBool::new(false);
        device.on_uncaptured_error(Arc::new(move |e| {
            if !reported.swap(true, Ordering::Relaxed) {
                eprintln!("lm: the window cannot draw: {}", one_line(&e));
            }
        }));
        self.shared.lock().size = (size.width, size.height);
        self.frame = frame;
        window.request_redraw();
        self.win = Some(Win { window, surface, config, renderer });
        Ok(())
    }

    /// Take the frame the machine has handed over, if it has handed one over
    /// since the last.
    fn take_frame(&mut self) {
        let mut s = self.shared.lock();
        if !std::mem::take(&mut s.fresh) {
            return;
        }
        std::mem::swap(&mut s.frame, &mut self.pixels);
        let (w, h) = s.frame_size;
        drop(s);
        if let Some(win) = self.win.as_mut() {
            win.renderer.upload(&self.pixels, w, h);
        }
        self.frame = (w, h);
        self.repoint();
    }

    fn redraw(&mut self) {
        self.take_frame();
        let Some(win) = self.win.as_mut() else { return };
        let size = win.window.inner_size();
        if size.width == 0 || size.height == 0 {
            return;
        }
        // The window can change size before it says so.
        if (size.width, size.height) != (win.config.width, win.config.height) {
            win.reconfigure(size);
        }
        let (texture, stale) = match win.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => (t, false),
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => (t, true),
            wgpu::CurrentSurfaceTexture::Outdated => {
                win.reconfigure(size);
                win.window.request_redraw();
                return;
            }
            // Lost, hidden or late: the next frame tries again.
            _ => return,
        };
        let view = texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        win.renderer.draw(&view, (win.config.width, win.config.height));
        win.window.pre_present_notify();
        win.renderer.queue().present(texture);
        if stale {
            win.reconfigure(size);
        }
    }

    fn resized(&mut self, size: PhysicalSize<u32>) {
        let Some(win) = self.win.as_mut() else { return };
        self.shared.lock().size = (size.width, size.height);
        // A minimised window is no size at all, and keeps its surface for
        // when it comes back.
        if size.width == 0 || size.height == 0 {
            return;
        }
        win.reconfigure(size);
        win.window.request_redraw();
        self.repoint();
    }

    /// Tell the machine where the pointer is in the frame, if that has
    /// changed: because it moved, or because the window or the frame changed
    /// under it.
    fn repoint(&mut self) {
        let (Some(at), Some(win)) = (self.cursor, self.win.as_ref()) else { return };
        let fit = Fit::new(self.frame, (win.config.width, win.config.height));
        let p = fit.frame_pixel(self.frame, at.x, at.y);
        if p != self.pointer {
            self.pointer = p;
            let mut s = self.shared.lock();
            s.pointer = p;
            s.post(pointer_word(EV_MOUSEMOVE, p.0, p.1, 0));
        }
    }

    fn key(&mut self, event_loop: &ActiveEventLoop, event: &KeyEvent, synthetic: bool) {
        if event.state == ElementState::Released {
            // Only a key seen going down comes up.
            if let Some(i) = self.keys.iter().position(|k| k.0 == event.physical_key) {
                let (_, code, ascii) = self.keys.remove(i);
                self.shared.lock().post(event_word(EV_KEYUP, ascii, code, 0));
            }
            return;
        }
        // Keys already held when the window gains focus are reported as
        // pressed, but they went down somewhere else.
        if synthetic {
            return;
        }
        if event.logical_key == Key::Named(NamedKey::Escape) && self.mods.control_key() {
            self.close(event_loop);
            return;
        }
        let (code, ascii) = keymap(event);
        match self.keys.iter_mut().find(|k| k.0 == event.physical_key) {
            Some(k) => *k = (event.physical_key, code, ascii),
            None => self.keys.push((event.physical_key, code, ascii)),
        }
        // A key held down repeats, as more presses.
        self.shared.lock().post(event_word(EV_KEYDOWN, ascii, code, 0));
    }

    fn modifiers(&mut self, m: ModifiersState) {
        self.mods = m;
        self.shared.lock().mods =
            m.shift_key() as u32 | (m.control_key() as u32) << 1 | (m.alt_key() as u32) << 2;
    }

    fn button(&mut self, state: ElementState, button: MouseButton) {
        let n = match button {
            MouseButton::Left => 0,
            MouseButton::Right => 1,
            MouseButton::Middle => 2,
            _ => return,
        };
        // A press already had, or the release of a press made outside.
        let down = state == ElementState::Pressed;
        if (self.buttons >> n & 1 != 0) == down {
            return;
        }
        self.buttons ^= 1 << n;
        let mut s = self.shared.lock();
        s.buttons = self.buttons;
        let kind = if down { EV_BUTTONDOWN } else { EV_BUTTONUP };
        s.post(pointer_word(kind, self.pointer.0, self.pointer.1, n));
    }

    fn wheel(&mut self, delta: MouseScrollDelta) {
        self.wheel += match delta {
            MouseScrollDelta::LineDelta(_, y) => y as f64,
            MouseScrollDelta::PixelDelta(p) => {
                let scale = self.win.as_ref().map_or(1.0, |w| w.window.scale_factor());
                p.y / (WHEEL_STEP * scale)
            }
        };
        // Fine wheels move a fraction of a step at a time, fractions that do
        // not add up to a whole one exactly.
        let steps = ((self.wheel * 4096.0).round() / 4096.0).trunc();
        if steps != 0.0 {
            self.wheel -= steps;
            // The step is twelve bits of two's complement.
            let step = steps.clamp(-2048.0, 2047.0) as i32 as u32;
            self.shared.lock().post(event_word(EV_WHEEL, 0, 0, step));
        }
    }

    /// Let go of every key and button held: once the window has lost focus
    /// it will not hear them come up.
    fn unfocused(&mut self) {
        let mut s = self.shared.lock();
        for (_, code, ascii) in self.keys.drain(..) {
            s.post(event_word(EV_KEYUP, ascii, code, 0));
        }
        for n in 0..3 {
            if self.buttons >> n & 1 != 0 {
                s.post(pointer_word(EV_BUTTONUP, self.pointer.0, self.pointer.1, n));
            }
        }
        self.buttons = 0;
        s.buttons = 0;
    }

    fn close(&mut self, event_loop: &ActiveEventLoop) {
        self.shared.lock().closed = true;
        event_loop.exit();
    }
}

impl ApplicationHandler<Wake> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        self.started = true;
        if let Some(wake) = self.early.take() {
            self.user_event(event_loop, wake);
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, wake: Wake) {
        match wake {
            Wake::Open { .. } if !self.started => self.early = Some(wake),
            Wake::Open { title, frame, scale, reply } => {
                let _ = reply.send(self.open(event_loop, &title, frame, scale));
            }
            Wake::Frame => {
                // The pointer is in the machine's current display from now,
                // whether or not it is drawn yet.
                let size = self.shared.lock().frame_size;
                if size != self.frame {
                    self.frame = size;
                    self.repoint();
                }
                if let Some(win) = &self.win {
                    win.window.request_redraw();
                }
            }
            Wake::Stopped => event_loop.exit(),
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::Resized(size) => self.resized(size),
            WindowEvent::CloseRequested => self.close(event_loop),
            WindowEvent::Focused(false) => self.unfocused(),
            WindowEvent::ModifiersChanged(m) => self.modifiers(m.state()),
            WindowEvent::KeyboardInput { event, is_synthetic, .. } => {
                self.key(event_loop, &event, is_synthetic)
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = Some(position);
                self.repoint();
            }
            WindowEvent::MouseInput { state, button, .. } => self.button(state, button),
            WindowEvent::MouseWheel { delta, .. } => self.wheel(delta),
            _ => {}
        }
    }
}

/// A wgpu error, which spreads its causes over several lines, on one.
fn one_line(e: &wgpu::Error) -> String {
    e.to_string().split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A key as the input chip reports it: (raw code, ascii).
///
/// A key that types a printable ASCII character has that character as its
/// ascii, as the layout, shift and caps lock make it, and the character it
/// types with no modifiers as its code. Return, tab, backspace, escape and
/// space have their ASCII as both. Other keys have ascii 0 and a code from
/// 0x80, or 0xff where the chip has none.
fn keymap(event: &KeyEvent) -> (u32, u32) {
    let code = match &event.logical_key {
        Key::Named(k) => named_code(*k),
        _ => match event.key_without_modifiers() {
            Key::Named(k) => named_code(k),
            Key::Character(s) if printable(&s) != 0 => printable(&s),
            // A character outside ASCII, from a layout that is not Latin: the
            // key's character on a US keyboard.
            _ => match event.physical_key {
                PhysicalKey::Code(k) => us_code(k),
                _ => 0xff,
            },
        },
    };
    let ascii = match &event.logical_key {
        Key::Character(s) => printable(s),
        Key::Named(_) if matches!(code, 8 | 9 | 13 | 27 | 32) => code,
        _ => 0,
    };
    (code, ascii)
}

/// The one printable ASCII character `s` holds, or 0.
fn printable(s: &str) -> u32 {
    match s.as_bytes() {
        [b @ 0x20..=0x7e] => *b as u32,
        _ => 0,
    }
}

fn named_code(k: NamedKey) -> u32 {
    use NamedKey::*;
    match k {
        Backspace => 8,
        Tab => 9,
        Enter => 13,
        Escape => 27,
        Space => 32,
        ArrowUp => 0x80,
        ArrowDown => 0x81,
        ArrowLeft => 0x82,
        ArrowRight => 0x83,
        Home => 0x84,
        End => 0x85,
        PageUp => 0x86,
        PageDown => 0x87,
        Insert => 0x88,
        Delete => 0x89,
        F1 => 0x90,
        F2 => 0x91,
        F3 => 0x92,
        F4 => 0x93,
        F5 => 0x94,
        F6 => 0x95,
        F7 => 0x96,
        F8 => 0x97,
        F9 => 0x98,
        F10 => 0x99,
        F11 => 0x9a,
        F12 => 0x9b,
        Shift => 0xa0,
        Control => 0xa1,
        Alt | AltGraph => 0xa2,
        _ => 0xff,
    }
}

/// The character a key types unshifted on a US keyboard.
fn us_code(k: KeyCode) -> u32 {
    use KeyCode::*;
    let c = match k {
        KeyA => b'a',
        KeyB => b'b',
        KeyC => b'c',
        KeyD => b'd',
        KeyE => b'e',
        KeyF => b'f',
        KeyG => b'g',
        KeyH => b'h',
        KeyI => b'i',
        KeyJ => b'j',
        KeyK => b'k',
        KeyL => b'l',
        KeyM => b'm',
        KeyN => b'n',
        KeyO => b'o',
        KeyP => b'p',
        KeyQ => b'q',
        KeyR => b'r',
        KeyS => b's',
        KeyT => b't',
        KeyU => b'u',
        KeyV => b'v',
        KeyW => b'w',
        KeyX => b'x',
        KeyY => b'y',
        KeyZ => b'z',
        Digit0 => b'0',
        Digit1 => b'1',
        Digit2 => b'2',
        Digit3 => b'3',
        Digit4 => b'4',
        Digit5 => b'5',
        Digit6 => b'6',
        Digit7 => b'7',
        Digit8 => b'8',
        Digit9 => b'9',
        Minus => b'-',
        Equal => b'=',
        BracketLeft => b'[',
        BracketRight => b']',
        Backslash => b'\\',
        Semicolon => b';',
        Quote => b'\'',
        Comma => b',',
        Period => b'.',
        Slash => b'/',
        Backquote => b'`',
        _ => return 0xff,
    };
    c as u32
}
