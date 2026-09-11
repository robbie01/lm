//! Keyboard and mouse. Events land in a fifo as packed words:
//!
//!     bits 31..28  kind: 1 key down, 2 key up, 3 mouse move,
//!                        4 button down, 5 button up, 6 wheel
//!     bits 27..20  ascii, when the key has one
//!     bits 19..12  raw key code
//!     bits 11..0   payload (button number, wheel delta)
//!
//! Mouse position is a register rather than an event, since polling it is what
//! a pointer actually wants.

use std::collections::VecDeque;

pub const I_EVENT: u32 = 0x00; // r: pop an event, or 0 when empty
pub const I_COUNT: u32 = 0x04;
pub const I_MOUSEX: u32 = 0x08;
pub const I_MOUSEY: u32 = 0x0c;
pub const I_BUTTONS: u32 = 0x10; // bit0 left, bit1 right, bit2 middle
pub const I_CTRL: u32 = 0x14; // bit0: raise INT_INPUT when an event arrives
pub const I_MODS: u32 = 0x18; // bit0 shift, bit1 ctrl, bit2 alt
/// w: queue this word as an event, as though it had come from the keyboard.
/// A loopback, which is what lets a test drive the input path end to end
/// without a window or a person.
pub const I_INJECT: u32 = 0x1c;

pub const EV_KEYDOWN: u32 = 1;
pub const EV_KEYUP: u32 = 2;
pub const EV_MOUSEMOVE: u32 = 3;
pub const EV_BUTTONDOWN: u32 = 4;
pub const EV_BUTTONUP: u32 = 5;
pub const EV_WHEEL: u32 = 6;

pub struct Input {
    q: VecDeque<u32>,
    pub mx: u32,
    pub my: u32,
    pub buttons: u32,
    pub mods: u32,
    pub ctrl: u32,
}

impl Input {
    pub fn new() -> Input {
        Input {
            q: VecDeque::new(),
            mx: 0,
            my: 0,
            buttons: 0,
            mods: 0,
            ctrl: 0,
        }
    }

    pub fn push(&mut self, kind: u32, ascii: u32, code: u32, payload: u32) {
        self.push_word((kind << 28) | ((ascii & 0xff) << 20) | ((code & 0xff) << 12) | (payload & 0xfff));
    }

    fn push_word(&mut self, w: u32) {
        if self.q.len() >= 512 {
            self.q.pop_front();
        }
        self.q.push_back(w);
    }

    pub fn pending(&self) -> bool {
        !self.q.is_empty()
    }

    pub fn read(&mut self, reg: u32) -> u32 {
        match reg {
            I_EVENT => self.q.pop_front().unwrap_or(0),
            I_COUNT => self.q.len() as u32,
            I_MOUSEX => self.mx,
            I_MOUSEY => self.my,
            I_BUTTONS => self.buttons,
            I_CTRL => self.ctrl,
            I_MODS => self.mods,
            _ => 0,
        }
    }

    pub fn write(&mut self, reg: u32, v: u32) {
        match reg {
            I_CTRL => self.ctrl = v,
            I_EVENT => self.q.clear(),
            I_INJECT => self.push_word(v),
            _ => {}
        }
    }
}
