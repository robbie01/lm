//! Serial console. Transmit goes straight to the host's stdout; receive is fed
//! by a reader thread so the emulated machine never blocks on the terminal.

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::mpsc::{channel, Receiver, TryRecvError};

pub const U_DATA: u32 = 0x00; // r: next byte, or -1 if the fifo is empty
pub const U_STATUS: u32 = 0x04; // r: bit0 rx ready, bit1 tx ready
pub const U_CTRL: u32 = 0x08; // rw: bit0 raise INT_UART when rx is ready
pub const U_COUNT: u32 = 0x0c; // r: bytes waiting

pub const ST_RX: u32 = 1;
pub const ST_TX: u32 = 2;

pub struct Uart {
    rx: VecDeque<u8>,
    src: Option<Receiver<u8>>,
    pub ctrl: u32,
    out: Vec<u8>,
    /// Set when stdin has reached end of file.
    pub eof: bool,
}

impl Uart {
    pub fn new() -> Uart {
        Uart {
            rx: VecDeque::new(),
            src: None,
            ctrl: 0,
            out: Vec::with_capacity(256),
            eof: false,
        }
    }

    /// Start pumping the host's stdin into the receive fifo.
    pub fn attach_stdin(&mut self) {
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let mut buf = [0u8; 256];
            let mut inp = std::io::stdin();
            loop {
                match inp.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        for &b in &buf[..n] {
                            if tx.send(b).is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        });
        self.src = Some(rx);
    }

    /// Queue text as if it had been typed. Used for scripted boots.
    pub fn feed(&mut self, s: &[u8]) {
        self.rx.extend(s.iter().copied());
    }

    /// Drain the host channel into the fifo. Returns true if anything arrived.
    pub fn poll(&mut self) -> bool {
        let before = self.rx.len();
        if let Some(src) = &self.src {
            loop {
                match src.try_recv() {
                    Ok(b) => self.rx.push_back(b),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        self.eof = true;
                        break;
                    }
                }
            }
        }
        self.rx.len() != before
    }

    pub fn rx_ready(&self) -> bool {
        !self.rx.is_empty()
    }

    pub fn read(&mut self, reg: u32) -> u32 {
        match reg {
            U_DATA => match self.rx.pop_front() {
                Some(b) => b as u32,
                None => u32::MAX,
            },
            U_STATUS => {
                ST_TX | if self.rx.is_empty() { 0 } else { ST_RX }
            }
            U_CTRL => self.ctrl,
            U_COUNT => self.rx.len() as u32,
            _ => 0,
        }
    }

    pub fn write(&mut self, reg: u32, v: u32) {
        match reg {
            U_DATA => {
                let b = v as u8;
                self.out.push(b);
                if b == b'\n' || self.out.len() >= 256 {
                    self.flush();
                }
            }
            U_CTRL => self.ctrl = v,
            _ => {}
        }
    }

    pub fn flush(&mut self) {
        if !self.out.is_empty() {
            let mut o = std::io::stdout();
            let _ = o.write_all(&self.out);
            let _ = o.flush();
            self.out.clear();
        }
    }
}
