//! Display. A chunky bitmap anywhere in chip RAM, shown in a host window.
//!
//! Vertical blank is derived from the retired-instruction count rather than
//! from host wall time, so a program that draws on every vblank produces the
//! exact same frames on every run. The host window is refreshed on those same
//! boundaries, throttled to whatever the host can actually keep up with.

use crate::dev::TIMER_HZ;
use crate::map::{CHIP_SIZE, INT_VBLANK};
use std::time::Instant;

pub const G_BASE: u32 = 0x00; // bitmap address in RAM
pub const G_WIDTH: u32 = 0x04;
pub const G_HEIGHT: u32 = 0x08;
pub const G_PITCH: u32 = 0x0c; // bytes per row
pub const G_MODE: u32 = 0x10; // 0 blank, 8 = indexed, 32 = xRGB
pub const G_PALIDX: u32 = 0x14;
pub const G_PALDAT: u32 = 0x18; // w: palette[idx] = 0xRRGGBB, then idx += 1
pub const G_CTRL: u32 = 0x1c; // bit0 display on, bit1 vblank interrupt on
pub const G_VCOUNT: u32 = 0x20; // r: frames elapsed
pub const G_SYNC: u32 = 0x24; // w: present immediately
pub const G_WINW: u32 = 0x28;
pub const G_WINH: u32 = 0x2c;
pub const G_HZ: u32 = 0x30; // r: vblanks per second

pub const CTRL_ON: u32 = 1;
pub const CTRL_VBIRQ: u32 = 2;

pub const VBL_HZ: u64 = 60;

pub struct Gfx {
    pub base: u32,
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
}

/// Something that can put a frame in front of a human. Keeps the window
/// toolkit out of the device model so headless runs need no display at all.
pub trait Present {
    fn show(&mut self, buf: &[u32], w: usize, h: usize) -> bool;
    fn size(&self) -> (u32, u32);
    fn pump(&mut self, ev: &mut crate::dev::input::Input);
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
            base: 0,
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
        }
    }

    pub fn wall_ms(&self) -> u32 {
        self.boot.elapsed().as_millis() as u32
    }

    pub fn read(&mut self, reg: u32) -> u32 {
        match reg {
            G_BASE => self.base,
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
            _ => 0,
        }
    }

    pub fn write(&mut self, reg: u32, v: u32) {
        match reg {
            G_BASE => self.base = v & !3,
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
        let base = self.base as usize;
        let pitch = self.pitch as usize;
        if self.ctrl & CTRL_ON == 0 || self.mode == 0 {
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

    /// True while the window is still open (always true when headless).
    pub fn present(&mut self, ram: &[u8], input: &mut crate::dev::input::Input) -> bool {
        if self.win.is_none() {
            return true;
        }
        // Do not spend more host time on redraw than the host can absorb.
        let due = self.force || self.last_present.elapsed().as_micros() >= 12_000;
        if !due {
            if let Some(w) = self.win.as_mut() {
                w.pump(input);
            }
            return true;
        }
        self.force = false;
        self.last_present = Instant::now();
        self.scanout(ram);
        let (w, h) = (self.width as usize, self.height as usize);
        let win = self.win.as_mut().unwrap();
        win.pump(input);
        if self.scan.len() < w * h {
            return true;
        }
        win.show(&self.scan, w, h)
    }

    /// Chip RAM the bitmap must fit inside, for the allocator's benefit.
    pub fn max_bitmap(&self) -> u32 {
        CHIP_SIZE
    }

    pub fn vblank_line(&self) -> u32 {
        INT_VBLANK
    }
}
