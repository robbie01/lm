//! Host window, on top of minifb. Everything the rest of the emulator sees is
//! the `Present` trait, so a headless build never touches this.

use crate::dev::gfx::Present;
use crate::dev::input::*;
use minifb::{Key, MouseButton, MouseMode, Scale, ScaleMode, Window, WindowOptions};

pub struct HostWindow {
    win: Window,
    down: Vec<Key>,
    last_mouse: (u32, u32),
    last_buttons: u32,
    /// The size of the last frame shown. The window shows that frame
    /// stretched to fit, so this is what a pointer position has to be turned
    /// back into.
    frame: (usize, usize),
}

impl HostWindow {
    pub fn open(title: &str, w: usize, h: usize, scale: u32) -> Result<HostWindow, String> {
        let opts = WindowOptions {
            resize: true,
            scale: match scale {
                2 => Scale::X2,
                4 => Scale::X4,
                _ => Scale::X1,
            },
            scale_mode: ScaleMode::AspectRatioStretch,
            ..WindowOptions::default()
        };
        let mut win = Window::new(title, w, h, opts).map_err(|e| e.to_string())?;
        // The emulator paces itself; do not let the toolkit add its own wait.
        win.set_target_fps(0);
        Ok(HostWindow {
            win,
            down: Vec::new(),
            last_mouse: (0, 0),
            last_buttons: 0,
            frame: (w, h),
        })
    }

    /// A point in the window, as a point in the frame it is showing: the
    /// inverse of `ScaleMode::AspectRatioStretch`, which scales the frame to
    /// fit without changing its shape and centres it, with bars down the sides
    /// or across the top and bottom.
    ///
    /// minifb reports the pointer in the window's own units and leaves the
    /// rest to us - its source says as much - so a click on something drawn at
    /// (300, 30) in a 1024 by 768 frame arrives, in a 640 by 400 window, as
    /// about (209, 15). Without this every click lands somewhere else, which
    /// is why raising, dragging and closing windows did nothing.
    ///
    /// The unscaled position and `get_size` are in the same units on every
    /// platform - pixels on Windows, points on macOS - and a ratio of like to
    /// like is all the arithmetic needs.
    fn to_frame(&self, x: f32, y: f32) -> (u32, u32) {
        let (fw, fh) = (self.frame.0 as f32, self.frame.1 as f32);
        let (ww, wh) = self.win.get_size();
        let (ww, wh) = (ww as f32, wh as f32);
        if fw < 1.0 || fh < 1.0 || ww < 1.0 || wh < 1.0 {
            return (x.max(0.0) as u32, y.max(0.0) as u32);
        }
        let scale = (ww / fw).min(wh / fh);
        let (ox, oy) = ((ww - fw * scale) / 2.0, (wh - fh * scale) / 2.0);
        let fx = ((x - ox) / scale).clamp(0.0, fw - 1.0);
        let fy = ((y - oy) / scale).clamp(0.0, fh - 1.0);
        (fx as u32, fy as u32)
    }
}

impl Present for HostWindow {
    fn show(&mut self, buf: &[u32], w: usize, h: usize) -> bool {
        if !self.win.is_open() || self.win.is_key_down(Key::Escape) && self.win.is_key_down(Key::LeftCtrl)
        {
            return false;
        }
        self.frame = (w, h);
        let _ = self.win.update_with_buffer(buf, w, h);
        true
    }

    fn size(&self) -> (u32, u32) {
        let (w, h) = self.win.get_size();
        (w as u32, h as u32)
    }

    fn pump(&mut self, ev: &mut Input) {
        if !self.win.is_open() {
            return;
        }
        self.win.update();

        let shift = self.win.is_key_down(Key::LeftShift) || self.win.is_key_down(Key::RightShift);
        let ctrl = self.win.is_key_down(Key::LeftCtrl) || self.win.is_key_down(Key::RightCtrl);
        let alt = self.win.is_key_down(Key::LeftAlt) || self.win.is_key_down(Key::RightAlt);
        ev.mods = (shift as u32) | ((ctrl as u32) << 1) | ((alt as u32) << 2);

        let now = self.win.get_keys();
        for k in &now {
            if !self.down.contains(k) {
                let (code, a) = keymap(*k, shift);
                ev.push(EV_KEYDOWN, a, code, 0);
            }
        }
        for k in &self.down {
            if !now.contains(k) {
                let (code, a) = keymap(*k, shift);
                ev.push(EV_KEYUP, a, code, 0);
            }
        }
        self.down = now;

        if let Some((x, y)) = self.win.get_unscaled_mouse_pos(MouseMode::Clamp) {
            let p = self.to_frame(x, y);
            if p != self.last_mouse {
                self.last_mouse = p;
                ev.mx = p.0;
                ev.my = p.1;
                ev.push_mouse(EV_MOUSEMOVE, p.0, p.1, 0);
            }
        }
        let b = (self.win.get_mouse_down(MouseButton::Left) as u32)
            | ((self.win.get_mouse_down(MouseButton::Right) as u32) << 1)
            | ((self.win.get_mouse_down(MouseButton::Middle) as u32) << 2);
        if b != self.last_buttons {
            for i in 0..3 {
                let was = self.last_buttons >> i & 1;
                let is = b >> i & 1;
                if was != is {
                    ev.push_mouse(
                        if is != 0 { EV_BUTTONDOWN } else { EV_BUTTONUP },
                        self.last_mouse.0,
                        self.last_mouse.1,
                        i,
                    );
                }
            }
            self.last_buttons = b;
            ev.buttons = b;
        }
        if let Some((_, dy)) = self.win.get_scroll_wheel() {
            if dy != 0.0 {
                ev.push(EV_WHEEL, 0, 0, (dy as i32 & 0xfff) as u32);
            }
        }
    }
}

/// Map a host key to (raw code, ascii). Printable keys use their own ASCII as
/// the raw code; everything else gets a code at 0x80 and above.
fn keymap(k: Key, shift: bool) -> (u32, u32) {
    use Key::*;
    let plain: Option<(u8, u8)> = match k {
        A => Some((b'a', b'A')),
        B => Some((b'b', b'B')),
        C => Some((b'c', b'C')),
        D => Some((b'd', b'D')),
        E => Some((b'e', b'E')),
        F => Some((b'f', b'F')),
        G => Some((b'g', b'G')),
        H => Some((b'h', b'H')),
        I => Some((b'i', b'I')),
        J => Some((b'j', b'J')),
        K => Some((b'k', b'K')),
        L => Some((b'l', b'L')),
        M => Some((b'm', b'M')),
        N => Some((b'n', b'N')),
        O => Some((b'o', b'O')),
        P => Some((b'p', b'P')),
        Q => Some((b'q', b'Q')),
        R => Some((b'r', b'R')),
        S => Some((b's', b'S')),
        T => Some((b't', b'T')),
        U => Some((b'u', b'U')),
        V => Some((b'v', b'V')),
        W => Some((b'w', b'W')),
        X => Some((b'x', b'X')),
        Y => Some((b'y', b'Y')),
        Z => Some((b'z', b'Z')),
        Key0 => Some((b'0', b')')),
        Key1 => Some((b'1', b'!')),
        Key2 => Some((b'2', b'@')),
        Key3 => Some((b'3', b'#')),
        Key4 => Some((b'4', b'$')),
        Key5 => Some((b'5', b'%')),
        Key6 => Some((b'6', b'^')),
        Key7 => Some((b'7', b'&')),
        Key8 => Some((b'8', b'*')),
        Key9 => Some((b'9', b'(')),
        Space => Some((b' ', b' ')),
        Minus => Some((b'-', b'_')),
        Equal => Some((b'=', b'+')),
        LeftBracket => Some((b'[', b'{')),
        RightBracket => Some((b']', b'}')),
        Backslash => Some((b'\\', b'|')),
        Semicolon => Some((b';', b':')),
        Apostrophe => Some((b'\'', b'"')),
        Comma => Some((b',', b'<')),
        Period => Some((b'.', b'>')),
        Slash => Some((b'/', b'?')),
        Backquote => Some((b'`', b'~')),
        Enter => Some((b'\r', b'\r')),
        Tab => Some((b'\t', b'\t')),
        Backspace => Some((8, 8)),
        Escape => Some((27, 27)),
        _ => None,
    };
    if let Some((lo, hi)) = plain {
        let a = if shift { hi } else { lo };
        return (lo as u32, a as u32);
    }
    let code = match k {
        Up => 0x80,
        Down => 0x81,
        Left => 0x82,
        Right => 0x83,
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
        LeftShift | RightShift => 0xa0,
        LeftCtrl | RightCtrl => 0xa1,
        LeftAlt | RightAlt => 0xa2,
        _ => 0xff,
    };
    (code, 0)
}
