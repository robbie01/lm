//! Display. A chunky bitmap anywhere in RAM, shown in a host window.
//!
//! The chip is handed the bitmap as a capability, in its scan-out register,
//! and shows only what that capability lets it read: tagged, unsealed, with
//! LD, and covering every row the other registers describe. A bitmap it may
//! not read is shown as a blank screen, and the status register says which
//! check failed, as the blitter's and the disk's do. A capability load from
//! the scan-out register hands back the capability it holds, as `LY` would
//! load it through the page: the chip keeps the bitmap on show for as long
//! as it shows it, and that is how the collector keeps it alive.
//!
//! Vertical blank is derived from the retired-instruction count rather than
//! from host wall time, so a program that draws on every vblank produces the
//! exact same frames on every run. The host window is shown a frame once per
//! vblank, when the machine next stops to wait, so that what was drawn in
//! answer to the blank is in it; a frame no different from the last is not
//! shown again.

use crate::cap::{Cap, P_LD};
use crate::dev::{REFUSE_LENGTH, REFUSE_LOAD, REFUSE_SEAL, REFUSE_TAG, TIMER_HZ};
use crate::map::{CHIP_SIZE, INT_VBLANK, RAM_SIZE};
use std::time::Instant;

/// The scan-out register: a capability register, 8 bytes, written with a
/// capability store and read back with a capability load. The bitmap starts
/// at its address.
pub const G_BASE: u32 = 0x00;
pub const G_WIDTH: u32 = 0x08;
pub const G_HEIGHT: u32 = 0x0c;
pub const G_PITCH: u32 = 0x10; // bytes per row
pub const G_MODE: u32 = 0x14; // 0 blank, 8 = indexed, 32 = xRGB
pub const G_PALIDX: u32 = 0x18;
pub const G_PALDAT: u32 = 0x1c; // w: palette[idx] = 0xRRGGBB, then idx += 1
pub const G_CTRL: u32 = 0x20; // bit0 display on, bit1 vblank interrupt on
pub const G_VCOUNT: u32 = 0x24; // r: frames elapsed
pub const G_SYNC: u32 = 0x28; // w: present immediately
pub const G_WINW: u32 = 0x2c;
pub const G_WINH: u32 = 0x30;
pub const G_HZ: u32 = 0x34; // r: vblanks per second
/// r: 0 if the scan-out capability lets the chip read the bitmap the other
/// registers describe, and otherwise the check it fails, as a `REFUSE_*`
/// code.
pub const G_STATUS: u32 = 0x38;

pub const CTRL_ON: u32 = 1;
pub const CTRL_VBIRQ: u32 = 2;

pub const VBL_HZ: u64 = 60;

pub struct Gfx {
    /// The scan-out capability.
    pub base: Cap,
    pub width: u32,
    pub height: u32,
    pub pitch: u32,
    pub mode: u32,
    pub ctrl: u32,
    pub palidx: u32,
    pub pal: [u32; 256],
    pub vcount: u32,
    /// Cycle count at which the next vertical blank lands.
    pub next_vbl: u64,
    pub win: Option<Box<dyn Present>>,
    pub scan: Vec<u32>,
    boot: Instant,
    last_present: Instant,
    pub force: bool,
    /// A vertical blank has passed since the window was last shown a frame.
    pub owed: bool,
    /// What the frame last shown was made from: the registers, the palette
    /// and the bytes of the bitmap. A frame made from the same is not shown
    /// again.
    shown: (Cap, u32, u32, u32, u32, u32),
    shown_pal: [u32; 256],
    shown_bytes: Vec<u8>,
}

/// A frame sink. Keeps the window toolkit out of the device model, so
/// headless runs need no display.
pub trait Present {
    /// Hand over a `w` by `h` frame of xRGB words. The sink may keep the
    /// buffer and give back another to convert the next frame into. False
    /// once the window has been closed.
    fn show(&mut self, frame: &mut Vec<u32>, w: usize, h: usize) -> bool;
    /// The window's size in host pixels.
    fn size(&self) -> (u32, u32);
    /// Move the input that has arrived into the input chip. False once the
    /// window has been closed.
    fn pump(&mut self, ev: &mut crate::dev::input::Input) -> bool;
    /// Sleep for `d`, or less if a key, a button or the wheel is waiting to
    /// be pumped; true if one is.
    fn wait(&mut self, d: std::time::Duration) -> bool {
        std::thread::sleep(d);
        false
    }
}

impl Gfx {
    pub fn new() -> Gfx {
        let mut pal = [0u32; 256];
        // A default ramp so an uninitialised palette still shows something:
        // 8 levels of red, 8 of green, 4 of blue, in the usual 3-3-2 layout.
        for (i, p) in pal.iter_mut().enumerate() {
            let r = ((i >> 5) & 7) * 255 / 7;
            let g = ((i >> 2) & 7) * 255 / 7;
            let b = (i & 3) * 255 / 3;
            *p = ((r as u32) << 16) | ((g as u32) << 8) | b as u32;
        }
        Gfx {
            base: Cap::NULL,
            width: 640,
            height: 400,
            pitch: 640,
            mode: 0,
            ctrl: 0,
            palidx: 0,
            pal,
            vcount: 0,
            next_vbl: TIMER_HZ as u64 / VBL_HZ,
            win: None,
            scan: Vec::new(),
            boot: Instant::now(),
            last_present: Instant::now(),
            force: false,
            owed: false,
            shown: (Cap::NULL, 0, 0, 0, 0, 0),
            shown_pal: [0; 256],
            shown_bytes: Vec::new(),
        }
    }

    pub fn wall_ms(&self) -> u32 {
        self.boot.elapsed().as_millis() as u32
    }

    /// The bytes a row of the bitmap takes.
    fn row_bytes(&self) -> usize {
        self.width as usize * if self.mode == 32 { 4 } else { 1 }
    }

    /// Why the chip may not read the bitmap the registers describe through
    /// the scan-out capability, as a `REFUSE_*` code: every row, from the
    /// capability's address, must lie inside its bounds and in RAM. None if
    /// it may, or if there is nothing to show.
    pub fn refusal(&self, ramlen: usize) -> Option<u32> {
        let (w, h) = (self.width as u64, self.height as u64);
        if self.ctrl & CTRL_ON == 0 || self.mode == 0 || w == 0 || h == 0 {
            return None;
        }
        let c = self.base;
        if !c.tag {
            return Some(REFUSE_TAG);
        }
        if c.is_sealed() {
            return Some(REFUSE_SEAL);
        }
        if !c.has(P_LD) {
            return Some(REFUSE_LOAD);
        }
        let at = c.addr as u64;
        let end = at + self.pitch as u64 * (h - 1) + self.row_bytes() as u64;
        let (b, t) = c.bounds();
        if at < b as u64 || end > t || end > ramlen as u64 {
            return Some(REFUSE_LENGTH);
        }
        None
    }

    pub fn read(&mut self, reg: u32) -> u32 {
        match reg {
            G_BASE => self.base.addr,
            G_WIDTH => self.width,
            G_HEIGHT => self.height,
            G_PITCH => self.pitch,
            G_MODE => self.mode,
            G_PALIDX => self.palidx,
            G_PALDAT => self.pal[(self.palidx & 255) as usize],
            G_CTRL => self.ctrl,
            G_VCOUNT => self.vcount,
            G_WINW => self.win.as_ref().map(|w| w.size().0).unwrap_or(self.width),
            G_WINH => self.win.as_ref().map(|w| w.size().1).unwrap_or(self.height),
            G_HZ => VBL_HZ as u32,
            G_STATUS => self.refusal(RAM_SIZE as usize).unwrap_or(0),
            _ => 0,
        }
    }

    /// A capability store to the scan-out register.
    pub fn write_cap(&mut self, c: Cap) {
        self.base = c;
    }

    pub fn write(&mut self, reg: u32, v: u32) {
        match reg {
            // A number is no capability: the chip is left with nothing to
            // show.
            G_BASE => self.base = Cap::int(v),
            G_WIDTH => self.width = v.min(4096),
            G_HEIGHT => self.height = v.min(4096),
            G_PITCH => self.pitch = v.min(1 << 16),
            G_MODE => self.mode = v,
            G_PALIDX => self.palidx = v & 255,
            G_PALDAT => {
                self.pal[(self.palidx & 255) as usize] = v & 0xff_ffff;
                self.palidx = (self.palidx + 1) & 255;
            }
            G_CTRL => self.ctrl = v,
            G_SYNC => self.force = true,
            _ => {}
        }
    }

    /// Convert the guest bitmap into the host's 32-bit scanout buffer.
    pub fn scanout(&mut self, ram: &[u8]) {
        let w = self.width as usize;
        let h = self.height as usize;
        if w == 0 || h == 0 {
            return;
        }
        if self.scan.len() != w * h {
            self.scan.resize(w * h, 0);
        }
        let base = self.base.addr as usize;
        let pitch = self.pitch as usize;
        if self.ctrl & CTRL_ON == 0 || self.mode == 0 || self.refusal(ram.len()).is_some() {
            self.scan.iter_mut().for_each(|p| *p = 0);
            return;
        }
        match self.mode {
            32 => {
                for y in 0..h {
                    let src = base + y * pitch;
                    let dst = y * w;
                    if src + w * 4 > ram.len() {
                        break;
                    }
                    for x in 0..w {
                        let o = src + x * 4;
                        self.scan[dst + x] = u32::from_le_bytes([
                            ram[o],
                            ram[o + 1],
                            ram[o + 2],
                            ram[o + 3],
                        ]) & 0xff_ffff;
                    }
                }
            }
            _ => {
                for y in 0..h {
                    let src = base + y * pitch;
                    let dst = y * w;
                    if src + w > ram.len() {
                        break;
                    }
                    let row = &ram[src..src + w];
                    let out = &mut self.scan[dst..dst + w];
                    for x in 0..w {
                        out[x] = self.pal[row[x] as usize];
                    }
                }
            }
        }
    }

    /// A vertical blank: move the host's input into the input chip, and owe
    /// the window the frame. True while the window is still open (always
    /// true when headless).
    pub fn frame(&mut self, input: &mut crate::dev::input::Input) -> bool {
        let Some(win) = self.win.as_mut() else { return true };
        self.owed = true;
        win.pump(input)
    }

    /// Show the window the frame it is owed. The machine calls this once it
    /// has stopped to wait after a vertical blank, so that what was drawn
    /// in answer to the blank is shown at once, and at the next blank if it
    /// never stopped. A picture made from exactly what the last was made
    /// from is not converted or handed over again. True while the window is
    /// still open.
    pub fn present(&mut self, ram: &[u8]) -> bool {
        if self.win.is_none() || !self.owed {
            return true;
        }
        // Converting a frame takes the machine's own thread; do not convert
        // many more than a display can show, which only a machine running
        // ahead of the wall clock would. Half a frame apart and not a whole
        // one, so that a frame shown late in its blank does not hold back the
        // next, shown early in its own. A frame held back stays owed.
        if !self.force && self.last_present.elapsed().as_micros() < 8_000 {
            return true;
        }
        self.owed = false;
        if !std::mem::take(&mut self.force) && self.unchanged(ram) {
            return true;
        }
        self.last_present = Instant::now();
        self.scanout(ram);
        let (w, h) = (self.width as usize, self.height as usize);
        if self.scan.len() < w * h {
            return true;
        }
        self.win.as_mut().unwrap().show(&mut self.scan, w, h)
    }

    /// Whether the picture would be made from what the last one shown was,
    /// remembering what this one is made from if not.
    fn unchanged(&mut self, ram: &[u8]) -> bool {
        let regs = (self.base, self.width, self.height, self.pitch, self.mode, self.ctrl);
        let row = self.row_bytes();
        let (base, pitch) = (self.base.addr as usize, self.pitch as usize);
        let h = if self.refusal(ram.len()).is_some() { 0 } else { self.height as usize };
        let rows = (0..h).map(|y| base + y * pitch).take_while(|&o| o + row <= ram.len());
        let same = regs == self.shown
            && self.pal == self.shown_pal
            && self.shown_bytes.len() == row * h
            && rows.clone().zip(self.shown_bytes.chunks_exact(row)).all(|(o, r)| ram[o..o + row] == *r);
        if !same {
            self.shown = regs;
            self.shown_pal = self.pal;
            self.shown_bytes.clear();
            for o in rows {
                self.shown_bytes.extend_from_slice(&ram[o..o + row]);
            }
        }
        same
    }

    /// Chip RAM the bitmap must fit inside, for the allocator's benefit.
    pub fn max_bitmap(&self) -> u32 {
        CHIP_SIZE
    }

    pub fn vblank_line(&self) -> u32 {
        INT_VBLANK
    }
}
