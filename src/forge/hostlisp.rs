//! The build-time Lisp, an interpreter that runs directly on the target heap.
//!
//! Its whole job is to run the compiler, which is written in Lisp, so that the
//! compiler can compile itself and everything else into the image. Because it
//! evaluates over the same object representation the machine uses, whatever it
//! builds is already in the form the machine expects: there is no separate
//! "host object" world and no conversion step.
//!
//! There are exactly nine special forms. Everything else - let*, cond, case,
//! and, or, when, unless, do, dolist, defun, quasiquote - is a macro written
//! in Lisp, so the interpreter and the compiler cannot disagree about the
//! language.

#![allow(dead_code)]

use crate::heap::*;
use crate::mach::Machine;
use crate::map::*;
use crate::forge::read::Reader;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Set every millisecond by a ticker thread when `LM_FORGE_PROF` is in the
/// environment; the evaluator notices at its next step and records which
/// interpreted function it is inside.
static PROF_TICK: AtomicBool = AtomicBool::new(false);

/// Where the build's time goes, by interpreted function. Sampled rather than
/// timed, because a clock read per call would cost more than most calls.
pub struct Prof {
    /// Interpreted closures being evaluated, innermost last. A tail call
    /// replaces the top rather than pushing, the way the evaluator does.
    stack: Vec<V>,
    own: HashMap<V, u64>,
    total: HashMap<V, u64>,
    prim_calls: Vec<u64>,
    samples: u64,
}

pub const T_PRIM: u32 = 9; // slot0 raw primitive index, slot1 name symbol

pub struct LErr {
    pub msg: String,
    pub trace: Vec<String>,
}

impl LErr {
    pub fn new(msg: impl Into<String>) -> LErr {
        LErr {
            msg: msg.into(),
            trace: Vec::new(),
        }
    }
}

impl std::fmt::Display for LErr {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        writeln!(f, "lisp error: {}", self.msg)?;
        for (i, t) in self.trace.iter().take(20).enumerate() {
            writeln!(f, "  {i:>2}. {t}")?;
        }
        Ok(())
    }
}

pub type Res = Result<V, LErr>;

macro_rules! bail {
    ($($t:tt)*) => { return Err(LErr::new(format!($($t)*))) };
}

/// Cached symbols, so the hot path in `eval` is pointer comparison rather than
/// string comparison.
pub struct Syms {
    pub quote: V,
    pub quasiquote: V,
    pub unquote: V,
    pub unquote_splicing: V,
    pub if_: V,
    pub lambda: V,
    pub set: V,
    pub define: V,
    pub begin: V,
    pub while_: V,
    pub let_: V,
    pub defmacro: V,
    pub t: V,
    pub optional: V,
    pub rest: V,
    pub macro_flag: V,
}

pub struct Lisp<'a> {
    pub h: Heap<'a>,
    pub s: Syms,
    pub depth: u32,
    pub load_path: Vec<String>,
    pub trace_calls: bool,
    /// Build-time global bindings.
    ///
    /// These deliberately do NOT live in the symbols' value cells. The value
    /// cell belongs to the machine: it is where `compile-top` installs the
    /// compiled closure that native code will call. If the two shared a slot,
    /// compiling `map` would immediately make `map` uncallable by the compiler
    /// that is still running - and the compiler is written in Lisp, so it
    /// would saw off the branch it is sitting on. Keeping the interpreter's
    /// bindings out here lets the whole library be compiled while the
    /// interpreted definitions carry on working.
    /// Keyed by name rather than by symbol. The bootstrap reader has one flat
    /// namespace - that is the whole point of it - while the sources it reads
    /// are divided into packages, so the same function is `hw:dev-addr` to the
    /// compiler and plain `dev-addr` here. The interpreter has to find it
    /// under the name the compiler asks for.
    // Indexed by the symbol's own identity - see `Heap::sym_index`. These
    // were maps keyed by the symbol's *name*, which meant that every global
    // reference in the build allocated a String out of the machine's heap and
    // then hashed it, and a macro check did it twice. It is the hottest thing
    // the forge does: the build is the compiler interpreted, and the compiler
    // is mostly calls to named functions.
    pub globals: Vec<Option<V>>,
    /// Build-time macros, kept out of the symbols' function cells for the same
    /// reason as `globals`: the function cell is where `compile-top` puts the
    /// compiled expander the machine's own compiler will use.
    /// Keyed by name, for the same reason `globals` is.
    pub macros: Vec<Option<V>>,
    /// Environments captured by interpreted closures. A heap slot cannot hold
    /// an Rc, so the closure stores an index into this table instead.
    pub envs: Vec<Env>,
    pub prof: Option<Box<Prof>>,
    /// Indexed by symbol identity: has any frame ever bound this symbol? One
    /// that has never been bound cannot be found in a frame, so a reference
    /// to it goes straight to the globals.
    pub lexbound: Vec<bool>,
}

impl Prof {
    fn from_env() -> Option<Box<Prof>> {
        std::env::var_os("LM_FORGE_PROF")?;
        std::thread::spawn(|| loop {
            std::thread::sleep(std::time::Duration::from_millis(1));
            PROF_TICK.store(true, Ordering::Relaxed);
        });
        Some(Box::new(Prof {
            stack: Vec::new(),
            own: HashMap::new(),
            total: HashMap::new(),
            prim_calls: vec![0; PRIMS.len()],
            samples: 0,
        }))
    }
}

/// One lexical frame. Reference counted, so a frame dies with the call that
/// made it unless a closure captured it.
pub struct Frame {
    pub vars: RefCell<Vars>,
    pub parent: Env,
}

pub type Env = Option<Rc<Frame>>;

/// A frame's bindings. Nearly every frame holds a handful, so those live in
/// the frame itself, and only one that outgrows that - a long `let`, or
/// internal defines piling up - moves them to a vector. A call used to cost
/// two allocations, the frame and a vector for its bindings; now it is one.
const VARS_INLINE: usize = 6;

pub enum Vars {
    Inline(usize, [(V, V); VARS_INLINE]),
    Heap(Vec<(V, V)>),
}

impl Vars {
    fn new() -> Vars {
        Vars::Inline(0, [(NIL, NIL); VARS_INLINE])
    }

    fn push(&mut self, b: (V, V)) {
        match self {
            Vars::Heap(v) => v.push(b),
            Vars::Inline(n, a) if *n < VARS_INLINE => {
                a[*n] = b;
                *n += 1;
            }
            Vars::Inline(_, a) => {
                let mut v = a.to_vec();
                v.push(b);
                *self = Vars::Heap(v);
            }
        }
    }

    fn as_slice(&self) -> &[(V, V)] {
        match self {
            Vars::Inline(n, a) => &a[..*n],
            Vars::Heap(v) => v,
        }
    }

    fn as_mut_slice(&mut self) -> &mut [(V, V)] {
        match self {
            Vars::Inline(n, a) => &mut a[..*n],
            Vars::Heap(v) => v,
        }
    }
}

enum Step {
    Val(V),
    Tail(V, Env),
}

impl<'a> Lisp<'a> {
    pub fn new(m: &'a mut Machine) -> Lisp<'a> {
        let mut h = Heap::new(m);
        h.format();
        let s = Syms {
            quote: h.intern("quote"),
            quasiquote: h.intern("quasiquote"),
            unquote: h.intern("unquote"),
            unquote_splicing: h.intern("unquote-splicing"),
            if_: h.intern("if"),
            lambda: h.intern("lambda"),
            set: h.intern("set!"),
            define: h.intern("define"),
            begin: h.intern("begin"),
            while_: h.intern("while"),
            let_: h.intern("let"),
            defmacro: h.intern("defmacro"),
            t: h.intern("t"),
            optional: h.intern("&optional"),
            rest: h.intern("&rest"),
            macro_flag: h.intern("%macro"),
        };
        // `t` evaluates to itself, and is the canonical true value.
        let tt = s.t;
        h.set_sym_value(tt, tt);
        let mut l = Lisp {
            h,
            s,
            depth: 0,
            load_path: vec!["lisp".into()],
            trace_calls: false,
            globals: Vec::new(),
            macros: Vec::new(),
            envs: Vec::new(),
            prof: Prof::from_env(),
            lexbound: Vec::new(),
        };
        let ts = l.h.intern("t");
        l.set_global(ts, tt);
        l.install_primitives();
        l
    }

    // ------------------------------------------------------------ environment
    // Environments live on the Rust side, not in the Lisp heap.
    //
    // They used to be alists of conses, and that turned out to dominate
    // build-time allocation: every call to every function in the compiler
    // built a frame that died the moment the call returned, and the heap has
    // no collector during the build. Reference-counted frames cost the
    // emulated machine nothing and go away on their own.
    // By reference down the chain rather than by clone: every variable
    // reference in the build walks this, and cloning bumped a refcount per
    // frame on the way for no reason - the frames are alive because `env`
    // holds them.
    fn lookup(&self, sym: V, env: &Env) -> Option<V> {
        let mut e = env.as_ref();
        while let Some(f) = e {
            for (s, v) in f.vars.borrow().as_slice().iter().rev() {
                if *s == sym {
                    return Some(*v);
                }
            }
            e = f.parent.as_ref();
        }
        None
    }

    fn set_var(&self, sym: V, env: &Env, val: V) -> bool {
        let mut e = env.as_ref();
        while let Some(f) = e {
            {
                let mut vars = f.vars.borrow_mut();
                for (s, v) in vars.as_mut_slice().iter_mut().rev() {
                    if *s == sym {
                        *v = val;
                        return true;
                    }
                }
            }
            e = f.parent.as_ref();
        }
        false
    }

    fn extend(env: &Env, vars: Vars) -> Env {
        Some(Rc::new(Frame {
            vars: RefCell::new(vars),
            parent: env.clone(),
        }))
    }

    /// Could this symbol be in a frame? Only if some frame has bound it. The
    /// compiler is mostly calls to global functions, and each of those used to
    /// search every enclosing frame for its name before trying the globals.
    fn maybe_lexical(&self, sym: V) -> bool {
        let i = self.h.sym_index(sym);
        i < self.lexbound.len() && self.lexbound[i]
    }

    /// Everything that puts a name in a frame says so here first. Two symbols
    /// that share an identity - which a symbol made without one would - only
    /// make the test say "maybe" more often, never "no" when it should not.
    fn mark_lexical(&mut self, sym: V) {
        if !self.h.is_symbol(sym) {
            return;
        }
        let i = self.h.sym_index(sym);
        if i >= self.lexbound.len() {
            self.lexbound.resize(i + 1, false);
        }
        self.lexbound[i] = true;
    }

    // ---------------------------------------------------------------- eval
    pub fn eval(&mut self, form0: V, env0: &Env) -> Res {
        let mut form = form0;
        let mut env = env0.clone();
        self.depth += 1;
        if self.depth > 100_000 {
            self.depth -= 1;
            bail!("evaluator recursion too deep");
        }
        let pbase = self.prof.as_ref().map_or(0, |p| p.stack.len());
        let r = loop {
            if PROF_TICK.load(Ordering::Relaxed) {
                self.prof_sample();
            }
            // self-evaluating
            if form == NIL || is_fixnum(form) || is_imm(form) {
                break Ok(form);
            }
            if is_obj(form) {
                if self.h.otype(form) == T_SYMBOL {
                    if self.maybe_lexical(form) {
                        if let Some(v) = self.lookup(form, &env) {
                            break Ok(v);
                        }
                    }
                    match self.get_global(form) {
                        Some(v) => break Ok(v),
                        None => {
                            // A constant the compiler has just worked out
                            // lives in the symbol's own cell in the heap.
                            let cell = self.h.sym_value(form);
                            if cell != UNBOUND {
                                break Ok(cell);
                            }
                            break Err(LErr::new(format!(
                                "unbound variable {}",
                                self.h.sym_name(form)
                            )));
                        }
                    }
                }
                // strings, vectors, floats and the like evaluate to themselves
                break Ok(form);
            }
            if !is_cons(form) {
                break Ok(form);
            }

            let head = self.h.car(form);
            let args = self.h.cdr(form);

            if self.h.is_symbol(head) {
                // ---- the nine special forms ----
                if head == self.s.quote {
                    break Ok(self.h.car(args));
                }
                if head == self.s.if_ {
                    let test = match self.eval(self.h.car(args), &env) {
                        Ok(v) => v,
                        Err(e) => break Err(e),
                    };
                    if test != NIL {
                        form = self.h.cadr(args);
                    } else {
                        let els = self.h.cddr(args);
                        if els == NIL {
                            break Ok(NIL);
                        }
                        form = self.h.car(els);
                    }
                    continue;
                }
                if head == self.s.lambda {
                    let params = self.h.car(args);
                    let body = self.h.cdr(args);
                    break Ok(self.make_closure(params, body, &env, NIL));
                }
                if head == self.s.begin {
                    if args == NIL {
                        break Ok(NIL);
                    }
                    // Everything but the last form runs for effect; the last
                    // stays in tail position, so tail recursion in the source
                    // does not grow the interpreter's own stack.
                    form = match self.body_tail(args, &env) {
                        Ok(f) => f,
                        Err(e) => return self.pop_err(e),
                    };
                    continue;
                }
                if head == self.s.set {
                    let name = self.h.car(args);
                    let val = match self.eval(self.h.cadr(args), &env) {
                        Ok(v) => v,
                        Err(e) => break Err(e),
                    };
                    if !(self.maybe_lexical(name) && self.set_var(name, &env, val)) {
                        self.set_global(name, val);
                    }
                    break Ok(val);
                }
                if head == self.s.define {
                    break self.eval_define(args, &env);
                }
                if head == self.s.defmacro {
                    break self.eval_defmacro(args, &env);
                }
                if head == self.s.while_ {
                    let test = self.h.car(args);
                    let body = self.h.cdr(args);
                    loop {
                        match self.eval(test, &env) {
                            Ok(NIL) => break,
                            Ok(_) => {}
                            Err(e) => return self.pop_err(e),
                        }
                        let mut p = body;
                        while is_cons(p) {
                            if let Err(e) = self.eval(self.h.car(p), &env) {
                                return self.pop_err(e);
                            }
                            p = self.h.cdr(p);
                        }
                    }
                    break Ok(NIL);
                }
                if head == self.s.let_ {
                    let binds = self.h.car(args);
                    let body = self.h.cdr(args);
                    let mut vars = Vars::new();
                    let mut failed = None;
                    let mut b = binds;
                    while is_cons(b) {
                        let bind = self.h.car(b);
                        b = self.h.cdr(b);
                        let (name, init) = if is_cons(bind) {
                            (self.h.car(bind), self.h.cadr(bind))
                        } else {
                            (bind, NIL)
                        };
                        self.mark_lexical(name);
                        match self.eval(init, &env) {
                            Ok(v) => vars.push((name, v)),
                            Err(e) => {
                                failed = Some(e);
                                break;
                            }
                        }
                    }
                    if let Some(e) = failed {
                        return self.pop_err(e);
                    }
                    env = Lisp::extend(&env, vars);
                    form = match self.body_tail(body, &env) {
                        Ok(f) => f,
                        Err(e) => return self.pop_err(e),
                    };
                    continue;
                }

                // ---- macro ----
                if let Some(mac) = self.get_macro(head) {
                    let margs = self.h.list_vec(args);
                    let expansion = match self.apply(mac, &margs) {
                        Ok(v) => v,
                        Err(mut e) => {
                            e.trace.push(format!("expanding {}", self.h.sym_name(head)));
                            return self.pop_err(e);
                        }
                    };
                    // Displace: overwrite the source cell with its expansion,
                    // so the macro runs once per site rather than once per
                    // evaluation. The compiler is a mass of `cond`s inside
                    // loops, and re-expanding them every time round cost more
                    // than everything else the interpreter does put together.
                    if is_cons(expansion) {
                        let (a, d) = (self.h.car(expansion), self.h.cdr(expansion));
                        self.h.set_car(form, a);
                        self.h.set_cdr(form, d);
                    } else {
                        // An atom still has to leave a cons behind, because the
                        // caller is holding a pointer to this very cell.
                        let tail = self.h.cons(expansion, NIL);
                        self.h.set_car(form, self.s.begin);
                        self.h.set_cdr(form, tail);
                    }
                    continue;
                }
            }

            // ---- application ----
            let f = match self.eval_operator(head, &env) {
                Ok(v) => v,
                Err(e) => break Err(e),
            };
            // Up to eight arguments stay on the Rust stack, and only a longer
            // call spills to a vector. That is almost every call, and a heap
            // allocation apiece was a real part of what a build cost.
            let mut buf = [NIL; 8];
            let mut n = 0usize;
            let mut spill: Vec<V> = Vec::new();
            let mut p = args;
            let mut failed = None;
            while is_cons(p) {
                match self.eval(self.h.car(p), &env) {
                    Ok(v) => {
                        if n < 8 {
                            buf[n] = v;
                        } else {
                            if n == 8 {
                                spill.extend_from_slice(&buf);
                            }
                            spill.push(v);
                        }
                        n += 1;
                    }
                    Err(e) => {
                        failed = Some(e);
                        break;
                    }
                }
                p = self.h.cdr(p);
            }
            if let Some(e) = failed {
                return self.pop_err(e);
            }
            let argv: &[V] = if n <= 8 { &buf[..n] } else { &spill };
            match self.apply_step(f, argv) {
                Ok(Step::Val(v)) => break Ok(v),
                Ok(Step::Tail(nf, ne)) => {
                    if let Some(p) = self.prof.as_mut() {
                        if p.stack.len() > pbase {
                            *p.stack.last_mut().unwrap() = f;
                        } else {
                            p.stack.push(f);
                        }
                    }
                    form = nf;
                    env = ne;
                    continue;
                }
                Err(e) => break Err(e),
            }
        };
        self.depth -= 1;
        if let Some(p) = self.prof.as_mut() {
            p.stack.truncate(pbase);
        }
        r
    }

    /// Who is running, for the profiler: a named function by its name, and a
    /// lambda by its body, so that every closure made from one lambda counts
    /// as the same thing.
    fn prof_key(&self, f: V) -> V {
        let n = self.h.slot(f, CLO_NAME);
        if self.h.is_symbol(n) {
            n
        } else {
            self.h.slot(f, CLO_BODY)
        }
    }

    fn prof_sample(&mut self) {
        PROF_TICK.store(false, Ordering::Relaxed);
        let Some(mut p) = self.prof.take() else { return };
        p.samples += 1;
        let top = p.stack.last().map_or(NIL, |&f| self.prof_key(f));
        *p.own.entry(top).or_insert(0) += 1;
        let mut seen: Vec<V> = Vec::new();
        for &f in p.stack.iter().rev() {
            let k = self.prof_key(f);
            if !seen.contains(&k) {
                seen.push(k);
                *p.total.entry(k).or_insert(0) += 1;
            }
        }
        self.prof = Some(p);
    }

    /// The profile, if one was taken: the functions the samples landed in,
    /// the functions they landed under, and the primitives called most.
    pub fn prof_report(&mut self) {
        let Some(p) = self.prof.take() else { return };
        let n = p.samples.max(1) as f64;
        let label = |l: &Lisp, k: V| -> String {
            if k == NIL {
                "(top level)".into()
            } else if l.h.is_symbol(k) {
                l.h.sym_name(k)
            } else {
                let mut s = l.h.write(k);
                s.truncate(70);
                format!("lambda {s}")
            }
        };
        eprintln!("forge profile: {} samples of 1ms", p.samples);
        let mut own: Vec<(&V, &u64)> = p.own.iter().collect();
        own.sort_by(|a, b| b.1.cmp(a.1));
        eprintln!("-- where the samples landed");
        for (k, c) in own.iter().take(45) {
            eprintln!("{:6.1}% {:6}  {}", 100.0 * **c as f64 / n, c, label(self, **k));
        }
        let mut total: Vec<(&V, &u64)> = p.total.iter().collect();
        total.sort_by(|a, b| b.1.cmp(a.1));
        eprintln!("-- what they landed under");
        for (k, c) in total.iter().take(45) {
            eprintln!("{:6.1}% {:6}  {}", 100.0 * **c as f64 / n, c, label(self, **k));
        }
        let mut prims: Vec<(usize, u64)> = p.prim_calls.iter().copied().enumerate().collect();
        prims.sort_by(|a, b| b.1.cmp(&a.1));
        let calls: u64 = prims.iter().map(|x| x.1).sum();
        eprintln!("-- primitive calls: {calls}");
        for (i, c) in prims.iter().take(30) {
            eprintln!("{:12}  {}", c, PRIMS[*i].0);
        }
    }

    fn pop_err(&mut self, e: LErr) -> Res {
        self.depth -= 1;
        Err(e)
    }

    /// One namespace: the head of a combination is looked up exactly the way
    /// any other variable is. Macros are the sole exception, and they are
    /// found before this ever runs.
    fn eval_operator(&mut self, head: V, env: &Env) -> Res {
        if self.h.is_symbol(head) {
            if self.maybe_lexical(head) {
                if let Some(v) = self.lookup(head, env) {
                    return Ok(v);
                }
            }
            if let Some(g) = self.get_global(head) {
                return Ok(g);
            }
            bail!("undefined function {}", self.h.sym_name(head))
        }
        self.eval(head, env)
    }

    fn is_macro(&mut self, sym: V) -> bool {
        self.get_macro(sym).is_some()
    }

    // `Option`, not a reserved value: `*unbound*` is a variable whose value is
    // the unbound marker, so "no entry" and "holds UNBOUND" are different
    // answers and the table has to be able to tell them apart.
    fn get_global(&mut self, sym: V) -> Option<V> {
        let i = self.h.name_id(sym);
        *self.globals.get(i)?
    }

    fn set_global(&mut self, sym: V, v: V) {
        let i = self.h.name_id(sym);
        if i >= self.globals.len() {
            self.globals.resize(i + 1, None);
        }
        self.globals[i] = Some(v);
    }

    fn get_macro(&mut self, sym: V) -> Option<V> {
        let i = self.h.name_id(sym);
        *self.macros.get(i)?
    }

    fn set_macro(&mut self, sym: V, v: V) {
        let i = self.h.name_id(sym);
        if i >= self.macros.len() {
            self.macros.resize(i + 1, None);
        }
        self.macros[i] = Some(v);
    }

    /// Look up a build-time global by name.
    pub fn global(&mut self, name: &str) -> V {
        let s = self.h.intern(name);
        self.get_global(s).unwrap_or(UNBOUND)
    }

    /// An interpreted closure. Slot 0 is zero, which is what marks it as
    /// interpreted; the environment is held on the Rust side and referred to
    /// by index, since an Rc cannot live in a heap slot.
    fn make_closure(&mut self, params: V, body: V, env: &Env, name: V) -> V {
        let mut p = params;
        while is_cons(p) {
            let s = self.h.car(p);
            self.mark_lexical(s);
            p = self.h.cdr(p);
        }
        self.mark_lexical(p);
        let idx = self.envs.len();
        self.envs.push(env.clone());
        let c = self.h.alloc_obj(T_CLOSURE, 5);
        self.h.set_slot(c, CLO_ENTRY, 0);
        self.h.set_slot(c, CLO_PARAMS, params);
        self.h.set_slot(c, CLO_BODY, body);
        self.h.set_slot(c, CLO_ENV, fix(idx as i32));
        self.h.set_slot(c, CLO_NAME, name);
        c
    }

    fn eval_define(&mut self, args: V, env: &Env) -> Res {
        let target = self.h.car(args);
        if is_cons(target) {
            // (define (name . params) . body)
            let name = self.h.car(target);
            let params = self.h.cdr(target);
            let body = self.h.cdr(args);
            let c = self.make_closure(params, body, env, name);
            self.set_global(name, c);
            return Ok(name);
        }
        let val = if self.h.cdr(args) == NIL {
            NIL
        } else {
            self.eval(self.h.cadr(args), env)?
        };
        if env.is_some() {
            self.mark_lexical(target);
        }
        match env {
            // An internal define adds to the innermost frame.
            Some(f) => f.vars.borrow_mut().push((target, val)),
            None => self.set_global(target, val),
        }
        Ok(target)
    }

    fn eval_defmacro(&mut self, args: V, env: &Env) -> Res {
        let name = self.h.car(args);
        let params = self.h.cadr(args);
        let body = self.h.cddr(args);
        let c = self.make_closure(params, body, env, name);
        self.set_macro(name, c);
        Ok(name)
    }

    // ---------------------------------------------------------------- apply
    pub fn apply(&mut self, f: V, argv: &[V]) -> Res {
        match self.apply_step(f, argv)? {
            Step::Val(v) => Ok(v),
            Step::Tail(form, env) => {
                if let Some(p) = self.prof.as_mut() {
                    p.stack.push(f);
                }
                let r = self.eval(form, &env);
                if let Some(p) = self.prof.as_mut() {
                    p.stack.pop();
                }
                r
            }
        }
    }

    fn apply_step(&mut self, f: V, argv: &[V]) -> Result<Step, LErr> {
        if self.h.is_type(f, T_PRIM) {
            let idx = self.h.slot(f, 0);
            return Ok(Step::Val(self.call_prim(idx, argv)?));
        }
        if !self.h.is_type(f, T_CLOSURE) {
            bail!("cannot apply {}", self.h.write(f));
        }
        if self.h.slot(f, CLO_ENTRY) != 0 {
            bail!("cannot run compiled code at build time");
        }
        let params = self.h.slot(f, CLO_PARAMS);
        let body = self.h.slot(f, CLO_BODY);
        let cenv = self.envs[unfix(self.h.slot(f, CLO_ENV)) as usize].clone();
        let vars = self.bind_params(f, params, argv)?;
        let env = Lisp::extend(&cenv, vars);
        let tail = self.body_tail(body, &env)?;
        Ok(Step::Tail(tail, env))
    }

    /// Run everything but the last form of a body, and hand the last one back
    /// for the caller to continue with in tail position.
    ///
    /// The obvious way to do this is to build `(begin . body)` and loop on
    /// that, and it costs one pair per call. The forge has no collector, so
    /// pairs spent are pairs gone - and the interpreter reads and compiles the
    /// whole system, which is millions of calls. This does the same thing and
    /// allocates nothing, on either side: it walks the list where it lies
    /// rather than copying it into a vector first.
    fn body_tail(&mut self, body: V, env: &Env) -> Result<V, LErr> {
        if !is_cons(body) {
            return Ok(NIL);
        }
        let mut p = body;
        loop {
            let next = self.h.cdr(p);
            if !is_cons(next) {
                return Ok(self.h.car(p));
            }
            self.eval(self.h.car(p), env)?;
            p = next;
        }
    }

    fn bind_params(&mut self, f: V, params: V, argv: &[V]) -> Result<Vars, LErr> {
        let mut vars = Vars::new();
        let mut p = params;
        let mut i = 0usize;
        let mut mode = 0; // 0 required, 1 optional, 2 rest
        while p != NIL {
            if !is_cons(p) {
                // dotted tail: bind the remainder as a list
                let rest = self.h.list(&argv[i.min(argv.len())..]);
                vars.push((p, rest));
                i = argv.len();
                break;
            }
            let name = self.h.car(p);
            if name == self.s.optional {
                mode = 1;
                p = self.h.cdr(p);
                continue;
            }
            if name == self.s.rest {
                mode = 2;
                p = self.h.cdr(p);
                continue;
            }
            if mode == 2 {
                let rest = self.h.list(&argv[i.min(argv.len())..]);
                vars.push((name, rest));
                i = argv.len();
                p = self.h.cdr(p);
                continue;
            }
            let val = if i < argv.len() {
                argv[i]
            } else if mode == 1 {
                NIL
            } else {
                bail!(
                    "{} wants more arguments than the {} it was given",
                    self.fn_name(f),
                    argv.len()
                );
            };
            vars.push((name, val));
            i += 1;
            p = self.h.cdr(p);
        }
        if i < argv.len() && mode != 2 {
            bail!(
                "{} was given {} arguments, too many",
                self.fn_name(f),
                argv.len()
            );
        }
        Ok(vars)
    }

    fn fn_name(&self, f: V) -> String {
        let nm = self.h.slot(f, CLO_NAME);
        if self.h.is_symbol(nm) {
            self.h.sym_name(nm)
        } else {
            "anonymous function".into()
        }
    }


    // ------------------------------------------------------------- loading
    pub fn eval_string(&mut self, text: &str, file: &str) -> Res {
        let forms = {
            let mut r = Reader::new(&mut self.h, text, file);
            match r.read_all() {
                Ok(f) => f,
                Err(e) => bail!("{e}"),
            }
        };
        let mut last = NIL;
        for f in forms {
            match self.eval(f, &None) {
                Ok(v) => last = v,
                Err(mut e) => {
                    e.trace.push(format!("in {file}: {}", self.h.write(f)));
                    return Err(e);
                }
            }
        }
        Ok(last)
    }

    /// Read and evaluate, using the reader written in Lisp rather than the
    /// bootstrap one. Everything the forge does after `read.lisp` is loaded
    /// goes through here, which is what makes the Lisp reader the only reader
    /// that decides what a name means.
    pub fn have_lisp_reader(&mut self) -> bool {
        let r = self.global("read-forms-from-string");
        r != UNBOUND && r != NIL
    }

    pub fn eval_lisp(&mut self, text: &str) -> Res {
        let start = self.global("start-reading-string");
        let next = self.global("read-next");
        let stop = self.global("stop-reading");
        let eof = self.global("*reader-eof*");
        if start == UNBOUND || next == UNBOUND {
            bail!("the Lisp reader is not loaded yet");
        }
        let arg = self.h.string(text);
        self.apply(start, &[arg])?;
        let mut last = NIL;
        loop {
            let f = match self.apply(next, &[]) {
                Ok(f) => f,
                Err(e) => {
                    let _ = self.apply(stop, &[]);
                    return Err(e);
                }
            };
            if f == eof {
                break;
            }
            match self.eval(f, &None) {
                Ok(v) => last = v,
                Err(mut e) => {
                    e.trace.push(format!("in <lisp>: {}", self.h.write(f)));
                    let _ = self.apply(stop, &[]);
                    return Err(e);
                }
            }
        }
        self.apply(stop, &[])?;
        Ok(last)
    }

    pub fn load(&mut self, name: &str) -> Res {
        for dir in self.load_path.clone() {
            let p = format!("{dir}/{name}");
            if let Ok(text) = std::fs::read_to_string(&p) {
                // Once the real reader is up it reads everything, so a file
                // loaded by hand is read the way the machine would read it.
                return if self.have_lisp_reader() {
                    self.eval_lisp(&text)
                } else {
                    self.eval_string(&text, &p)
                };
            }
        }
        bail!("cannot find {name}")
    }

    // ---------------------------------------------------------- primitives
    fn defprim(&mut self, name: &str, idx: u32) {
        // Primitives are the machine's own vocabulary and belong to everyone:
        // every package can say %car without asking.
        let sym = self.h.intern(name);
        self.h.set_exported(sym);
        let p = self.h.alloc_obj(T_PRIM, 2);
        self.h.set_slot(p, 0, idx);
        self.h.set_slot(p, 1, sym);
        let s = self.h.intern(name);
        self.set_global(s, p);
    }

    fn install_primitives(&mut self) {
        for (i, (name, _)) in PRIMS.iter().enumerate() {
            self.defprim(name, i as u32);
        }
    }

    fn need(&self, argv: &[V], n: usize, who: &str) -> Result<(), LErr> {
        if argv.len() < n {
            return Err(LErr::new(format!(
                "{who} needs {n} arguments, got {}",
                argv.len()
            )));
        }
        Ok(())
    }

    fn num(&self, v: V, who: &str) -> Result<i32, LErr> {
        if is_fixnum(v) {
            Ok(unfix(v))
        } else {
            Err(LErr::new(format!(
                "{who} wants a number, got {}",
                self.h.write(v)
            )))
        }
    }

    /// Compare two numbers of either kind: -1, 0 or 1.
    fn cmp2(&self, a: &[V], who: &str) -> Result<i32, LErr> {
        match self.h.num_cmp(a[0], a[1]) {
            Some(c) => Ok(c),
            None => Err(LErr::new(format!(
                "{who} wants numbers, got {} and {}",
                self.h.write(a[0]),
                self.h.write(a[1])
            ))),
        }
    }

    fn call_prim(&mut self, idx: u32, a: &[V]) -> Res {
        if let Some(p) = self.prof.as_mut() {
            p.prim_calls[idx as usize] += 1;
        }
        let (name, _) = PRIMS[idx as usize];
        macro_rules! n {
            ($i:expr) => {
                self.num(a[$i], name)?
            };
        }
        macro_rules! need {
            ($k:expr) => {
                self.need(a, $k, name)?
            };
        }
        let r = match PRIM_OF[idx as usize] {
            // ---- pairs ----
            Prim::Cons => {
                need!(2);
                self.h.cons(a[0], a[1])
            }
            Prim::Car => {
                need!(1);
                if !is_cons(a[0]) && a[0] != NIL {
                    bail!("car of {}", self.h.write(a[0]))
                }
                self.h.car(a[0])
            }
            Prim::Cdr => {
                need!(1);
                if !is_cons(a[0]) && a[0] != NIL {
                    bail!("cdr of {}", self.h.write(a[0]))
                }
                self.h.cdr(a[0])
            }
            Prim::SetCarX => {
                need!(2);
                self.h.set_car(a[0], a[1]);
                a[1]
            }
            Prim::SetCdrX => {
                need!(2);
                self.h.set_cdr(a[0], a[1]);
                a[1]
            }

            // ---- arithmetic ----
            Prim::Add => {
                need!(2);
                fix(n!(0).wrapping_add(n!(1)))
            }
            // The trapping forms. On the machine these fault and the handler
            // widens them; here there is no trap to take, so they widen
            // directly. Same answers either way, which is what matters: the
            // build evaluates constant arithmetic and the image has to agree
            // with it.
            Prim::AddO => {
                need!(2);
                match self.h.num_add(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            Prim::SubO => {
                need!(2);
                match self.h.num_sub(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            Prim::MulO => {
                need!(2);
                match self.h.num_mul(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            Prim::Mulhi16 => {
                need!(2);
                fix((((n!(0) as u32) * (n!(1) as u32)) >> 16) as i32)
            }
            Prim::Sub => {
                need!(2);
                fix(n!(0).wrapping_sub(n!(1)))
            }
            Prim::Mul => {
                need!(2);
                fix(n!(0).wrapping_mul(n!(1)))
            }
            Prim::Div => {
                need!(2);
                let d = n!(1);
                if d == 0 {
                    bail!("division by zero")
                }
                fix(n!(0).wrapping_div(d))
            }
            Prim::Mod => {
                need!(2);
                let d = n!(1);
                if d == 0 {
                    bail!("modulo by zero")
                }
                fix(n!(0).rem_euclid(d))
            }
            Prim::Rem => {
                need!(2);
                let d = n!(1);
                if d == 0 {
                    bail!("remainder by zero")
                }
                fix(n!(0).wrapping_rem(d))
            }
            // The comparisons take a bignum on either side, the way the
            // machine's do once the trap handler has widened them. `eqv?` on
            // two bignums is spelled `%=` for exactly this reason: each side
            // of the bootstrap answers it with its own arithmetic.
            Prim::NumEq => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c == 0)
            }
            Prim::Lt => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c < 0)
            }
            Prim::Gt => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c > 0)
            }
            Prim::Le => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c <= 0)
            }
            Prim::Ge => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c >= 0)
            }
            Prim::Logand => {
                need!(2);
                fix(n!(0) & n!(1))
            }
            Prim::Logior => {
                need!(2);
                fix(n!(0) | n!(1))
            }
            Prim::Logxor => {
                need!(2);
                fix(n!(0) ^ n!(1))
            }
            Prim::Lognot => {
                need!(1);
                fix(!n!(0))
            }
            Prim::Ash => {
                need!(2);
                let v = n!(0);
                let s = n!(1);
                fix(if s >= 0 {
                    ((v as u32) << (s & 31)) as i32
                } else {
                    v >> ((-s) & 31)
                })
            }
            Prim::Lsh => {
                need!(2);
                let v = n!(0) as u32;
                let s = n!(1);
                fix(if s >= 0 {
                    (v << (s & 31)) as i32
                } else {
                    (v >> ((-s) & 31)) as i32
                })
            }

            // ---- identity and type ----
            Prim::EqP => {
                need!(2);
                self.bool(a[0] == a[1])
            }
            Prim::NullP => {
                need!(1);
                self.bool(a[0] == NIL)
            }
            Prim::FixnumP => {
                need!(1);
                self.bool(is_fixnum(a[0]))
            }
            Prim::ConsP => {
                need!(1);
                self.bool(is_cons(a[0]))
            }
            Prim::SymbolP => {
                need!(1);
                self.bool(self.h.is_symbol(a[0]))
            }
            Prim::StringP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_STRING))
            }
            Prim::VectorP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_VECTOR))
            }
            Prim::BytesP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_BYTES))
            }
            Prim::ClosureP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_CLOSURE) || self.h.is_type(a[0], T_PRIM))
            }
            Prim::CharP => {
                need!(1);
                self.bool(is_char(a[0]))
            }
            Prim::FloatP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_FLOAT))
            }
            Prim::BignumP => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_BIGNUM))
            }
            Prim::ObjectP => {
                need!(1);
                self.bool(is_obj(a[0]))
            }

            // ---- raw object access ----
            Prim::AllocObj => {
                need!(2);
                self.h.alloc_obj(n!(0) as u32, n!(1) as u32)
            }
            Prim::ObjType => {
                need!(1);
                fix(self.h.otype(a[0]) as i32)
            }
            Prim::ObjLen => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            // The bootstrap interpreter does not check the type the way the
            // machine's instruction does; it is here so that the same source
            // reads on both sides of the bootstrap.
            Prim::Slot | Prim::RecordRef => {
                need!(2);
                self.h.slot(a[0], n!(1) as u32)
            }
            Prim::SetSlotX | Prim::RecordSetX => {
                need!(3);
                let i = n!(1) as u32;
                self.h.set_slot(a[0], i, a[2]);
                a[2]
            }

            // ---- raw memory: the assembler and the kernel live here ----
            Prim::LdByte => {
                need!(1);
                fix(self.h.m.peek8(n!(0) as u32) as i32)
            }
            Prim::LdHalf => {
                need!(1);
                fix(self.h.m.peek16(n!(0) as u32) as i32)
            }
            Prim::LdFixnum => {
                need!(1);
                let w = self.h.m.peek32(n!(0) as u32);
                fix(w as i32)
            }
            Prim::StByteX => {
                need!(2);
                self.h.m.poke8(n!(0) as u32, n!(1) as u8);
                a[1]
            }
            Prim::StHalfX => {
                need!(2);
                let addr = n!(0) as u32;
                let v = n!(1) as u32;
                self.h.m.poke8(addr, v as u8);
                self.h.m.poke8(addr + 1, (v >> 8) as u8);
                a[1]
            }
            Prim::StFixnumX => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, n!(1) as u32);
                a[1]
            }
            Prim::Ld32u => {
                // Read a word as an unsigned value split across two fixnums is
                // overkill; the heap never needs the top bit at build time.
                need!(1);
                fix((self.h.m.peek32(n!(0) as u32) & 0x7fff_ffff) as i32)
            }
            // Read and write a word without retagging, for moving tagged
            // values through raw addresses.
            Prim::LdWord => {
                need!(1);
                self.h.m.peek32(n!(0) as u32)
            }
            Prim::StWordX => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, a[1]);
                a[1]
            }
            // At build time there is no machine stack to scan, and no
            // collector to scan it; an empty range keeps the shared source
            // honest without pretending otherwise.
            Prim::StackPointer => fix(0),
            Prim::FramePointer => fix(0),
            Prim::WaitForInput => NIL,
            Prim::Ecall => NIL,
            Prim::SyncConsRun => NIL,
            Prim::ReloadConsRun => NIL,
            Prim::SetContext => NIL,
            Prim::EnableTimer => NIL,
            Prim::Cycles => fix(0),
            Prim::Disable => NIL,
            Prim::RestoreInterrupts => NIL,
            Prim::EnableAfterTrap => NIL,
            Prim::Enable => NIL,
            Prim::Halt => {
                bail!("the build tried to halt the machine")
            }
            Prim::AddrOf => {
                need!(1);
                fix(a[0] as i32)
            }
            Prim::FromAddr => {
                need!(1);
                n!(0) as u32
            }

            // ---- allocation regions ----
            Prim::AllocCode => {
                need!(1);
                fix(self.h.alloc_code(n!(0) as u32) as i32)
            }
            Prim::AllocPool => {
                need!(1);
                fix(self.h.alloc_pool(n!(0) as u32) as i32)
            }
            Prim::Global => {
                need!(1);
                fix(self.h.m.peek32(n!(0) as u32) as i32)
            }
            Prim::SetGlobalX => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, n!(1) as u32);
                a[1]
            }

            // ---- strings, vectors, bytes ----
            Prim::MakeString => {
                need!(1);
                let n = n!(0) as u32;
                let fillc = if a.len() > 1 { imm_payload(a[1]) as u8 } else { 32 };
                let p = self.h.alloc_obj(T_STRING, n);
                for i in 0..n {
                    self.h.m.poke8(p + i, fillc);
                }
                p
            }
            Prim::StringLength | Prim::BytesLength => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            Prim::StringRef => {
                need!(2);
                chr(self.h.m.peek8(a[0] + n!(1) as u32) as u32)
            }
            Prim::StringSetX => {
                need!(3);
                let off = n!(1) as u32;
                let c = if is_char(a[2]) {
                    imm_payload(a[2]) as u8
                } else {
                    self.num(a[2], name)? as u8
                };
                self.h.m.poke8(a[0] + off, c);
                a[2]
            }
            Prim::MakeVector => {
                need!(1);
                let n = n!(0) as u32;
                let fillv = if a.len() > 1 { a[1] } else { NIL };
                let p = self.h.alloc_obj(T_VECTOR, n);
                for i in 0..n {
                    self.h.set_slot(p, i, fillv);
                }
                p
            }
            Prim::VectorLength => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            Prim::VectorRef => {
                need!(2);
                let i = n!(1) as u32;
                if i >= self.h.olen(a[0]) {
                    bail!("vector index {i} out of range")
                }
                self.h.slot(a[0], i)
            }
            Prim::VectorSetX => {
                need!(3);
                let i = n!(1) as u32;
                if i >= self.h.olen(a[0]) {
                    bail!("vector index {i} out of range")
                }
                self.h.set_slot(a[0], i, a[2]);
                a[2]
            }
            Prim::MakeBytes => {
                need!(1);
                let n = n!(0) as u32;
                let p = self.h.alloc_obj(T_BYTES, n);
                for i in 0..n {
                    self.h.m.poke8(p + i, 0);
                }
                p
            }
            Prim::BytesRef => {
                need!(2);
                fix(self.h.m.peek8(a[0] + n!(1) as u32) as i32)
            }
            Prim::BytesSetX => {
                need!(3);
                let off = n!(1) as u32;
                let v = n!(2) as u8;
                self.h.m.poke8(a[0] + off, v);
                a[2]
            }

            // ---- symbols ----
            Prim::Intern => {
                need!(1);
                let s = self.h.str_of(a[0]);
                self.h.intern(&s)
            }
            Prim::SymbolName => {
                need!(1);
                self.h.slot(a[0], SYM_NAME)
            }
            Prim::SymbolValue => {
                need!(1);
                self.h.slot(a[0], SYM_VALUE)
            }
            // Where a *variable reference* looks, which here is the globals
            // map: a symbol's own cell holds the closure `compile-top` bound
            // for the image, and running that is what "cannot run compiled
            // code at build time" is about. A fluid binding has to land in
            // the world doing the reading, so it uses these two rather than
            // the pair above.
            Prim::FluidValue => {
                need!(1);
                match self.get_global(a[0]) {
                    Some(v) => v,
                    None => self.h.slot(a[0], SYM_VALUE),
                }
            }
            Prim::SetFluidValueX => {
                need!(2);
                if self.get_global(a[0]).is_some() {
                    self.set_global(a[0], a[1]);
                } else {
                    self.h.set_slot(a[0], SYM_VALUE, a[1]);
                }
                a[1]
            }
            Prim::SetSymbolValueX => {
                need!(2);
                self.h.set_slot(a[0], SYM_VALUE, a[1]);
                a[1]
            }
            Prim::SymbolFunction => {
                need!(1);
                self.h.slot(a[0], SYM_FUNCTION)
            }
            Prim::SetSymbolFunctionX => {
                need!(2);
                self.h.set_slot(a[0], SYM_FUNCTION, a[1]);
                a[1]
            }
            Prim::SymbolPlist => {
                need!(1);
                self.h.slot(a[0], SYM_PLIST)
            }
            Prim::SetSymbolPlistX => {
                need!(2);
                self.h.set_slot(a[0], SYM_PLIST, a[1]);
                a[1]
            }
            Prim::SymbolFlags => {
                need!(1);
                self.h.slot(a[0], SYM_FLAGS)
            }
            Prim::SetSymbolFlagsX => {
                need!(2);
                self.h.set_slot(a[0], SYM_FLAGS, a[1]);
                a[1]
            }
            Prim::AllSymbols => self.h.g(LG_SYMLIST),
            Prim::Obarray => self.h.obarray(),

            // ---- characters ----
            Prim::CharToInt => {
                need!(1);
                fix(imm_payload(a[0]) as i32)
            }
            Prim::IntToChar => {
                need!(1);
                chr(n!(0) as u32)
            }

            // ---- closures ----
            Prim::MakeClosure => {
                need!(2);
                // (entry nfree) -> a compiled closure with room for free vars
                let nfree = n!(1) as u32;
                let c = self.h.alloc_obj(T_CLOSURE, 2 + nfree);
                self.h.set_slot(c, CLO_ENTRY, n!(0) as u32);
                c
            }
            Prim::ClosureEntry => {
                need!(1);
                fix(self.h.slot(a[0], CLO_ENTRY) as i32)
            }
            Prim::Apply => {
                need!(2);
                let args = self.h.list_vec(a[1]);
                return self.apply(a[0], &args);
            }
            Prim::Funcall => {
                need!(1);
                return self.apply(a[0], &a[1..]);
            }

            // ---- build-time only ----
            Prim::Write => {
                need!(1);
                print!("{}", self.h.write(a[0]));
                a[0]
            }
            Prim::Display => {
                need!(1);
                print!("{}", self.h.display(a[0]));
                a[0]
            }
            Prim::Newline => {
                println!();
                NIL
            }
            Prim::Flush => {
                use std::io::Write;
                let _ = std::io::stdout().flush();
                NIL
            }
            Prim::Error => {
                let mut msg = String::new();
                for (i, x) in a.iter().enumerate() {
                    if i > 0 {
                        msg.push(' ');
                    }
                    msg.push_str(&self.h.display(*x));
                }
                bail!("{msg}")
            }
            Prim::ReadFile => {
                need!(1);
                let path = self.h.str_of(a[0]);
                match std::fs::read_to_string(&path) {
                    Ok(t) => self.h.string(&t),
                    Err(e) => bail!("cannot read {path}: {e}"),
                }
            }
            Prim::Load => {
                need!(1);
                let n = self.h.str_of(a[0]);
                return self.load(&n);
            }
            Prim::Macroexpand1 => {
                need!(1);
                let form = a[0];
                if is_cons(form) {
                    let head = self.h.car(form);
                    if let Some(mac) = self.get_macro(head) {
                        let args = self.h.list_vec(self.h.cdr(form));
                        return self.apply(mac, &args);
                    }
                }
                form
            }
            Prim::MacroP => {
                need!(1);
                let m = self.is_macro(a[0]);
                self.bool(m)
            }
            Prim::Gensym => {
                let n = self.h.g(LG_GCCOUNT);
                self.h.set_g(LG_GCCOUNT, n + 1);
                let nm = format!("g{n}");
                self.h.intern(&nm)
            }
            Prim::Eval => {
                need!(1);
                return self.eval(a[0], &None);
            }
            Prim::Exit => {
                let c = if a.is_empty() { 0 } else { n!(0) };
                std::process::exit(c);
            }
        };
        Ok(r)
    }

    fn bool(&self, b: bool) -> V {
        if b {
            self.s.t
        } else {
            NIL
        }
    }
}

// Every primitive, once. The same list makes the table the interpreter
// installs from and the enum `call_prim` dispatches on, so the two cannot
// disagree about which number is which.
//
// Dispatch used to match the name as a string: a comparison per arm, per
// call, and a build makes seventy million calls. An enum match is a jump.
macro_rules! prims {
    ($($id:ident $name:literal $arity:literal;)*) => {
        #[derive(Clone, Copy)]
        enum Prim { $($id),* }
        /// (name, arity hint). The arity hint is documentation; checks happen inline.
        pub static PRIMS: &[(&str, u32)] = &[$(($name, $arity)),*];
        static PRIM_OF: &[Prim] = &[$(Prim::$id),*];
    };
}

prims! {
    Cons               "%cons" 2;
    Car                "%car" 1;
    Cdr                "%cdr" 1;
    SetCarX            "%set-car!" 2;
    SetCdrX            "%set-cdr!" 2;
    Add                "%+" 2;
    Sub                "%-" 2;
    Mul                "%*" 2;
    Div                "%/" 2;
    Mod                "%mod" 2;
    AddO               "%+o" 2;
    SubO               "%-o" 2;
    MulO               "%*o" 2;
    Mulhi16            "%mulhi16" 2;
    Rem                "%rem" 2;
    NumEq              "%=" 2;
    Lt                 "%<" 2;
    Gt                 "%>" 2;
    Le                 "%<=" 2;
    Ge                 "%>=" 2;
    Logand             "%logand" 2;
    Logior             "%logior" 2;
    Logxor             "%logxor" 2;
    Lognot             "%lognot" 1;
    Ash                "%ash" 2;
    Lsh                "%lsh" 2;
    EqP                "%eq?" 2;
    NullP              "%null?" 1;
    FixnumP            "%fixnum?" 1;
    ConsP              "%cons?" 1;
    SymbolP            "%symbol?" 1;
    StringP            "%string?" 1;
    VectorP            "%vector?" 1;
    BytesP             "%bytes?" 1;
    ClosureP           "%closure?" 1;
    CharP              "%char?" 1;
    FloatP             "%float?" 1;
    BignumP            "%bignum?" 1;
    ObjectP            "%object?" 1;
    AllocObj           "%alloc-obj" 2;
    ObjType            "%obj-type" 1;
    ObjLen             "%obj-len" 1;
    Slot               "%slot" 2;
    SetSlotX           "%set-slot!" 3;
    RecordRef          "%record-ref" 2;
    RecordSetX         "%record-set!" 3;
    LdByte             "%ld-byte" 1;
    LdHalf             "%ld-half" 1;
    LdFixnum           "%ld-fixnum" 1;
    StByteX            "%st-byte!" 2;
    StHalfX            "%st-half!" 2;
    StFixnumX          "%st-fixnum!" 2;
    Ld32u              "%ld32u" 1;
    LdWord             "%ld-word" 1;
    StWordX            "%st-word!" 2;
    StackPointer       "%stack-pointer" 0;
    FramePointer       "%frame-pointer" 0;
    WaitForInput       "%wait-for-input" 0;
    Ecall              "%ecall" 1;
    SyncConsRun        "%sync-cons-run" 0;
    ReloadConsRun      "%reload-cons-run" 0;
    SetContext         "%set-context" 1;
    EnableTimer        "%enable-timer" 0;
    Cycles             "%cycles" 0;
    Disable            "%disable" 0;
    RestoreInterrupts  "%restore-interrupts" 1;
    EnableAfterTrap    "%enable-after-trap" 0;
    Enable             "%enable" 0;
    Halt               "%halt" 1;
    AddrOf             "%addr-of" 1;
    FromAddr           "%from-addr" 1;
    AllocCode          "%alloc-code" 1;
    AllocPool          "%alloc-pool" 1;
    Global             "%global" 1;
    SetGlobalX         "%set-global!" 2;
    MakeString         "%make-string" 1;
    StringLength       "%string-length" 1;
    StringRef          "%string-ref" 2;
    StringSetX         "%string-set!" 3;
    MakeVector         "%make-vector" 1;
    VectorLength       "%vector-length" 1;
    VectorRef          "%vector-ref" 2;
    VectorSetX         "%vector-set!" 3;
    MakeBytes          "%make-bytes" 1;
    BytesLength        "%bytes-length" 1;
    BytesRef           "%bytes-ref" 2;
    BytesSetX          "%bytes-set!" 3;
    Intern             "%intern" 1;
    SymbolName         "%symbol-name" 1;
    SymbolValue        "%symbol-value" 1;
    FluidValue         "%fluid-value" 1;
    SetFluidValueX     "%set-fluid-value!" 2;
    SetSymbolValueX    "%set-symbol-value!" 2;
    SymbolFunction     "%symbol-function" 1;
    SetSymbolFunctionX "%set-symbol-function!" 2;
    SymbolPlist        "%symbol-plist" 1;
    SetSymbolPlistX    "%set-symbol-plist!" 2;
    SymbolFlags        "%symbol-flags" 1;
    SetSymbolFlagsX    "%set-symbol-flags!" 2;
    AllSymbols         "%all-symbols" 0;
    Obarray            "%obarray" 0;
    CharToInt          "%char->int" 1;
    IntToChar          "%int->char" 1;
    MakeClosure        "%make-closure" 2;
    ClosureEntry       "%closure-entry" 1;
    Apply              "%apply" 2;
    Funcall            "%funcall" 1;
    Write              "%write" 1;
    Display            "%display" 1;
    Newline            "%newline" 0;
    Flush              "%flush" 0;
    Error              "%error" 1;
    ReadFile           "%read-file" 1;
    Load               "%load" 1;
    Macroexpand1       "%macroexpand-1" 1;
    MacroP             "%macro?" 1;
    Gensym             "%gensym" 0;
    Eval               "%eval" 1;
    Exit               "%exit" 0;
}
