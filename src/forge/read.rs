//! The build-time reader. Text in, heap structure out.
//!
//! There is a second reader written in Lisp that ends up compiled into the
//! image for the REPL to use; this one exists only to break the bootstrap
//! circle, since something has to read the reader.

use crate::heap::*;

pub struct Reader<'a, 'b> {
    pub h: &'a mut Heap<'b>,
    src: Vec<char>,
    pos: usize,
    pub file: String,
    pub line: u32,
    /// Inside a `defpackage` or `in-package` form, where the names are the
    /// names of packages that may not exist yet. Reading them as symbols
    /// would intern them in whatever package happens to be current, which is
    /// exactly the wrong one.
    raw: bool,
    depth: u32,
}

#[derive(Debug)]
pub struct ReadErr {
    pub msg: String,
    pub file: String,
    pub line: u32,
}

impl std::fmt::Display for ReadErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}:{}: {}", self.file, self.line, self.msg)
    }
}

type R<T> = Result<T, ReadErr>;

impl<'a, 'b> Reader<'a, 'b> {
    pub fn new(h: &'a mut Heap<'b>, text: &str, file: &str) -> Reader<'a, 'b> {
        Reader {
            h,
            src: text.chars().collect(),
            pos: 0,
            file: file.to_string(),
            line: 1,
            raw: false,
            depth: 0,
        }
    }

    fn err<T>(&self, msg: impl Into<String>) -> R<T> {
        Err(ReadErr {
            msg: msg.into(),
            file: self.file.clone(),
            line: self.line,
        })
    }

    fn peek(&self) -> Option<char> {
        self.src.get(self.pos).copied()
    }
    fn peek2(&self) -> Option<char> {
        self.src.get(self.pos + 1).copied()
    }
    fn bump(&mut self) -> Option<char> {
        let c = self.peek();
        if c == Some('\n') {
            self.line += 1;
        }
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn skip_space(&mut self) -> R<()> {
        loop {
            match self.peek() {
                Some(c) if c.is_whitespace() => {
                    self.bump();
                }
                Some(';') => {
                    while let Some(c) = self.bump() {
                        if c == '\n' {
                            break;
                        }
                    }
                }
                Some('#') if self.peek2() == Some('|') => {
                    self.bump();
                    self.bump();
                    let mut depth = 1;
                    while depth > 0 {
                        match self.bump() {
                            None => return self.err("unterminated block comment"),
                            Some('|') if self.peek() == Some('#') => {
                                self.bump();
                                depth -= 1;
                            }
                            Some('#') if self.peek() == Some('|') => {
                                self.bump();
                                depth += 1;
                            }
                            _ => {}
                        }
                    }
                }
                // #; datum comment: read the next form and throw it away
                Some('#') if self.peek2() == Some(';') => {
                    self.bump();
                    self.bump();
                    self.read()?;
                }
                _ => return Ok(()),
            }
        }
    }

    /// Read one form, or None at end of input.
    pub fn read(&mut self) -> R<Option<V>> {
        self.skip_space()?;
        let c = match self.peek() {
            None => return Ok(None),
            Some(c) => c,
        };
        match c {
            ')' => {
                self.bump();
                self.err("unexpected )")
            }
            '(' => {
                self.bump();
                Ok(Some(self.read_list(')')?))
            }
            '[' => {
                self.bump();
                Ok(Some(self.read_list(']')?))
            }
            '\'' => {
                self.bump();
                self.wrap("quote")
            }
            '`' => {
                self.bump();
                self.wrap("quasiquote")
            }
            ',' => {
                self.bump();
                if self.peek() == Some('@') {
                    self.bump();
                    self.wrap("unquote-splicing")
                } else {
                    self.wrap("unquote")
                }
            }
            '"' => {
                self.bump();
                Ok(Some(self.read_string()?))
            }
            '#' => self.read_hash(),
            _ => Ok(Some(self.read_atom()?)),
        }
    }

    fn wrap(&mut self, sym: &str) -> R<Option<V>> {
        let inner = match self.read()? {
            Some(v) => v,
            None => return self.err(format!("{sym} needs a form after it")),
        };
        let s = self.h.intern(sym);
        let tail = self.h.cons(inner, NIL);
        Ok(Some(self.h.cons(s, tail)))
    }

    fn read_hash(&mut self) -> R<Option<V>> {
        self.bump(); // '#'
        match self.peek() {
            Some('(') => {
                self.bump();
                let l = self.read_list(')')?;
                let items = self.h.list_vec(l);
                Ok(Some(self.h.vector(&items)))
            }
            Some('\\') => {
                self.bump();
                Ok(Some(self.read_char()?))
            }
            Some('x') | Some('X') => {
                self.bump();
                self.read_radix(16)
            }
            Some('b') | Some('B') => {
                self.bump();
                self.read_radix(2)
            }
            Some('o') | Some('O') => {
                self.bump();
                self.read_radix(8)
            }
            Some('d') | Some('D') => {
                self.bump();
                self.read_radix(10)
            }
            Some('t') => {
                self.bump();
                Ok(Some(self.h.intern("t")))
            }
            Some('f') => {
                self.bump();
                Ok(Some(NIL))
            }
            _ => self.err("unknown # syntax"),
        }
    }

    fn read_radix(&mut self, radix: u32) -> R<Option<V>> {
        let tok = self.token();
        match i64::from_str_radix(&tok, radix) {
            Ok(n) => Ok(Some(fix(n as i32))),
            Err(_) => self.err(format!("bad radix-{radix} literal {tok:?}")),
        }
    }

    fn read_char(&mut self) -> R<V> {
        // A named character, or a single literal one.
        let first = match self.bump() {
            None => return self.err("end of input after #\\"),
            Some(c) => c,
        };
        if first.is_alphabetic() {
            let mut name = String::new();
            name.push(first);
            while let Some(c) = self.peek() {
                if c.is_alphanumeric() || c == '-' {
                    name.push(c);
                    self.bump();
                } else {
                    break;
                }
            }
            if name.chars().count() == 1 {
                return Ok(chr(first as u32));
            }
            let c = match name.as_str() {
                "space" => ' ',
                "newline" | "linefeed" => '\n',
                "tab" => '\t',
                "return" => '\r',
                "nul" | "null" => '\0',
                "escape" | "esc" => '\x1b',
                "backspace" => '\x08',
                "delete" | "rubout" => '\x7f',
                _ => return self.err(format!("unknown character name {name:?}")),
            };
            return Ok(chr(c as u32));
        }
        Ok(chr(first as u32))
    }

    fn read_string(&mut self) -> R<V> {
        let mut s = String::new();
        loop {
            match self.bump() {
                None => return self.err("unterminated string"),
                Some('"') => break,
                Some('\\') => {
                    let e = match self.bump() {
                        None => return self.err("unterminated escape"),
                        Some(e) => e,
                    };
                    s.push(match e {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '0' => '\0',
                        'e' => '\x1b',
                        other => other,
                    });
                }
                Some(c) => s.push(c),
            }
        }
        Ok(self.h.string(&s))
    }

    fn read_list(&mut self, close: char) -> R<V> {
        let mut items: Vec<V> = Vec::new();
        let mut tail = NIL;
        let outer_raw = self.raw;
        self.depth += 1;
        loop {
            self.skip_space()?;
            match self.peek() {
                None => return self.err("unterminated list"),
                Some(c) if c == close => {
                    self.bump();
                    break;
                }
                Some(')') | Some(']') => {
                    self.bump();
                    break;
                }
                Some('.') if self.dot_ahead() => {
                    self.bump();
                    tail = match self.read()? {
                        Some(v) => v,
                        None => return self.err("nothing after ."),
                    };
                    self.skip_space()?;
                    match self.peek() {
                        Some(c) if c == close => {
                            self.bump();
                        }
                        _ => return self.err("expected ) after dotted tail"),
                    }
                    break;
                }
                _ => match self.read()? {
                    Some(v) => {
                        // The head of the form decides how the rest of it is
                        // read: package names are names, not symbols.
                        // Only the outermost form: `(define (defpackage
                        // name . clauses) ...)` is a definition of it, not a
                        // use of it, and its parameters are parameters.
                        if items.is_empty() && self.depth == 1 && self.h.is_symbol(v) {
                            let n = self.h.sym_name(v);
                            if n == "defpackage" || n == "in-package" {
                                self.raw = true;
                            }
                        }
                        items.push(v)
                    }
                    None => return self.err("unterminated list"),
                },
            }
        }
        self.raw = outer_raw;
        self.depth -= 1;
        let mut r = tail;
        for &x in items.iter().rev() {
            r = self.h.cons(x, r);
        }
        Ok(r)
    }

    /// A lone `.` used as the dotted-pair marker, as opposed to a symbol that
    /// merely starts with a dot.
    fn dot_ahead(&self) -> bool {
        match self.src.get(self.pos + 1) {
            None => false,
            Some(c) => c.is_whitespace() || *c == ')' || *c == ']',
        }
    }

    fn token(&mut self) -> String {
        let mut s = String::new();
        while let Some(c) = self.peek() {
            if c.is_whitespace() || "()[]\";'`,".contains(c) {
                break;
            }
            s.push(c);
            self.bump();
        }
        s
    }

    /// Split `pkg:name` or `pkg::name`. Answers the package part, the name,
    /// and whether the internal symbols were asked for.
    fn split_qualified(tok: &str) -> Option<(String, String, bool)> {
        let i = tok.find(':')?;
        if i == 0 {
            return None; // a name that merely starts with a colon
        }
        let rest = &tok[i + 1..];
        let (name, double) = match rest.strip_prefix(':') {
            Some(r) => (r, true),
            None => (rest, false),
        };
        if name.is_empty() || name.contains(':') {
            return None;
        }
        Some((tok[..i].to_string(), name.to_string(), double))
    }

    fn read_atom(&mut self) -> R<V> {
        let tok = self.token();
        if tok.is_empty() {
            return self.err("empty token");
        }
        if self.raw {
            return Ok(self.h.string(&tok));
        }
        if let Some(v) = parse_number(&tok) {
            return Ok(match v {
                Num::Int(n) => {
                    if !(-(1 << 30)..(1 << 30)).contains(&n) {
                        return self.err(format!("integer {n} does not fit a fixnum"));
                    }
                    fix(n as i32)
                }
                Num::Float(f) => self.h.float(f),
            });
        }
        if tok == "nil" {
            return Ok(NIL);
        }
        if let Some((pkg, name, internal)) = Reader::split_qualified(&tok) {
            let p = match self.h.find_package(&pkg) {
                Some(p) => p,
                None => return self.err(format!("no package named {pkg}")),
            };
            let s = self.h.find_in(p, &name);
            if s != NIL {
                if !internal && !self.h.exported(s) {
                    return self.err(format!("{pkg} does not export {name}"));
                }
                return Ok(s);
            }
            if !internal {
                return self.err(format!("{pkg} does not export {name}"));
            }
            return Ok(self.h.intern_in(p, &name));
        }
        let cur = self.h.cur_package();
        Ok(self.h.intern_visible(cur, &tok))
    }

    /// `in-package` and `defpackage` take effect as they are read, because
    /// everything after them in the file is read in the package they name.
    /// The evaluator does the same thing again later, to no further effect.
    pub fn package_form(&mut self, form: V) {
        if !is_cons(form) {
            return;
        }
        let head = self.h.car(form);
        if !self.h.is_symbol(head) {
            return;
        }
        let hn = self.h.sym_name(head);
        let args = self.h.cdr(form);
        if !is_cons(args) {
            return;
        }
        let first = self.h.car(args);
        if self.h.otype_is_string(first) {
            let name = self.h.str_of(first);
            if hn == "in-package" {
                let p = self.h.package(&name);
                self.h.set_cur_package(p);
            } else if hn == "defpackage" {
                let p = self.h.package(&name);
                let mut names: Vec<String> = Vec::new();
                let mut in_use = false;
                let mut w = self.h.cdr(args);
                while is_cons(w) {
                    let x = self.h.car(w);
                    if self.h.otype_is_string(x) {
                        let sx = self.h.str_of(x);
                        if sx == "use" {
                            in_use = true;
                        } else if in_use {
                            names.push(sx);
                        }
                    }
                    w = self.h.cdr(w);
                }
                let mut list = NIL;
                for nm in names.iter().rev() {
                    let used = self.h.package(nm);
                    list = self.h.cons(used, list);
                }
                self.h.set_slot(p, PKG_USE, list);
            }
        }
    }

    /// Read every form in the text into a list.
    pub fn read_all(&mut self) -> R<Vec<V>> {
        let mut out = Vec::new();
        while let Some(v) = self.read()? {
            self.package_form(v);
            out.push(v);
        }
        Ok(out)
    }
}

pub enum Num {
    Int(i64),
    Float(f32),
}

pub fn parse_number(tok: &str) -> Option<Num> {
    let b = tok.as_bytes();
    let first = *b.first()?;
    // A leading sign only makes a number if something follows it.
    if !(first.is_ascii_digit() || ((first == b'-' || first == b'+') && b.len() > 1)) {
        return None;
    }
    if let Some(hex) = tok.strip_prefix("0x").or_else(|| tok.strip_prefix("0X")) {
        return i64::from_str_radix(hex, 16).ok().map(Num::Int);
    }
    if let Ok(n) = tok.parse::<i64>() {
        return Some(Num::Int(n));
    }
    if tok.contains('.') || tok.contains('e') || tok.contains('E') {
        if let Ok(f) = tok.parse::<f32>() {
            return Some(Num::Float(f));
        }
    }
    None
}
