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
use std::rc::Rc;

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
}

/// One lexical frame. Reference counted, so a frame dies with the call that
/// made it unless a closure captured it.
pub struct Frame {
    pub vars: RefCell<Vec<(V, V)>>,
    pub parent: Env,
}

pub type Env = Option<Rc<Frame>>;

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
            for (s, v) in f.vars.borrow().iter().rev() {
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
                for (s, v) in vars.iter_mut().rev() {
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

    fn extend(env: &Env, vars: Vec<(V, V)>) -> Env {
        Some(Rc::new(Frame {
            vars: RefCell::new(vars),
            parent: env.clone(),
        }))
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
        let r = loop {
            // self-evaluating
            if form == NIL || is_fixnum(form) || is_imm(form) {
                break Ok(form);
            }
            if is_obj(form) {
                if self.h.otype(form) == T_SYMBOL {
                    if let Some(v) = self.lookup(form, &env) {
                        break Ok(v);
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
                    let items = self.h.list_vec(args);
                    let mut bad = None;
                    for x in &items[..items.len() - 1] {
                        if let Err(e) = self.eval(*x, &env) {
                            bad = Some(e);
                            break;
                        }
                    }
                    if let Some(e) = bad {
                        return self.pop_err(e);
                    }
                    form = items[items.len() - 1];
                    continue;
                }
                if head == self.s.set {
                    let name = self.h.car(args);
                    let val = match self.eval(self.h.cadr(args), &env) {
                        Ok(v) => v,
                        Err(e) => break Err(e),
                    };
                    if !self.set_var(name, &env, val) {
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
                    let body = self.h.list_vec(self.h.cdr(args));
                    loop {
                        match self.eval(test, &env) {
                            Ok(NIL) => break,
                            Ok(_) => {}
                            Err(e) => return self.pop_err(e),
                        }
                        for x in &body {
                            if let Err(e) = self.eval(*x, &env) {
                                return self.pop_err(e);
                            }
                        }
                    }
                    break Ok(NIL);
                }
                if head == self.s.let_ {
                    let binds = self.h.list_vec(self.h.car(args));
                    let body = self.h.cdr(args);
                    let mut vars: Vec<(V, V)> = Vec::with_capacity(binds.len());
                    let mut failed = None;
                    for bind in binds {
                        let (name, init) = if is_cons(bind) {
                            (self.h.car(bind), self.h.cadr(bind))
                        } else {
                            (bind, NIL)
                        };
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
            let mut argv: Vec<V> = Vec::new();
            let mut p = args;
            let mut failed = None;
            while is_cons(p) {
                match self.eval(self.h.car(p), &env) {
                    Ok(v) => argv.push(v),
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
            match self.apply_step(f, &argv) {
                Ok(Step::Val(v)) => break Ok(v),
                Ok(Step::Tail(nf, ne)) => {
                    form = nf;
                    env = ne;
                    continue;
                }
                Err(e) => break Err(e),
            }
        };
        self.depth -= 1;
        r
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
            if let Some(v) = self.lookup(head, env) {
                return Ok(v);
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
            Step::Tail(form, env) => self.eval(form, &env),
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
    /// allocates nothing.
    fn body_tail(&mut self, body: V, env: &Env) -> Result<V, LErr> {
        let items = self.h.list_vec(body);
        let Some((last, rest)) = items.split_last() else {
            return Ok(NIL);
        };
        for x in rest {
            self.eval(*x, env)?;
        }
        Ok(*last)
    }

    fn bind_params(&mut self, f: V, params: V, argv: &[V]) -> Result<Vec<(V, V)>, LErr> {
        let mut vars: Vec<(V, V)> = Vec::new();
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
        let r = match name {
            // ---- pairs ----
            "%cons" => {
                need!(2);
                self.h.cons(a[0], a[1])
            }
            "%car" => {
                need!(1);
                if !is_cons(a[0]) && a[0] != NIL {
                    bail!("car of {}", self.h.write(a[0]))
                }
                self.h.car(a[0])
            }
            "%cdr" => {
                need!(1);
                if !is_cons(a[0]) && a[0] != NIL {
                    bail!("cdr of {}", self.h.write(a[0]))
                }
                self.h.cdr(a[0])
            }
            "%set-car!" => {
                need!(2);
                self.h.set_car(a[0], a[1]);
                a[1]
            }
            "%set-cdr!" => {
                need!(2);
                self.h.set_cdr(a[0], a[1]);
                a[1]
            }

            // ---- arithmetic ----
            "%+" => {
                need!(2);
                fix(n!(0).wrapping_add(n!(1)))
            }
            // The trapping forms. On the machine these fault and the handler
            // widens them; here there is no trap to take, so they widen
            // directly. Same answers either way, which is what matters: the
            // build evaluates constant arithmetic and the image has to agree
            // with it.
            "%+o" => {
                need!(2);
                match self.h.num_add(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            "%-o" => {
                need!(2);
                match self.h.num_sub(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            "%*o" => {
                need!(2);
                match self.h.num_mul(a[0], a[1]) {
                    Some(v) => v,
                    None => return Err(LErr::new(format!("{name} wants numbers"))),
                }
            }
            "%mulhi16" => {
                need!(2);
                fix((((n!(0) as u32) * (n!(1) as u32)) >> 16) as i32)
            }
            "%-" => {
                need!(2);
                fix(n!(0).wrapping_sub(n!(1)))
            }
            "%*" => {
                need!(2);
                fix(n!(0).wrapping_mul(n!(1)))
            }
            "%/" => {
                need!(2);
                let d = n!(1);
                if d == 0 {
                    bail!("division by zero")
                }
                fix(n!(0).wrapping_div(d))
            }
            "%mod" => {
                need!(2);
                let d = n!(1);
                if d == 0 {
                    bail!("modulo by zero")
                }
                fix(n!(0).rem_euclid(d))
            }
            "%rem" => {
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
            "%=" => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c == 0)
            }
            "%<" => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c < 0)
            }
            "%>" => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c > 0)
            }
            "%<=" => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c <= 0)
            }
            "%>=" => {
                need!(2);
                let c = self.cmp2(a, name)?;
                self.bool(c >= 0)
            }
            "%logand" => {
                need!(2);
                fix(n!(0) & n!(1))
            }
            "%logior" => {
                need!(2);
                fix(n!(0) | n!(1))
            }
            "%logxor" => {
                need!(2);
                fix(n!(0) ^ n!(1))
            }
            "%lognot" => {
                need!(1);
                fix(!n!(0))
            }
            "%ash" => {
                need!(2);
                let v = n!(0);
                let s = n!(1);
                fix(if s >= 0 {
                    ((v as u32) << (s & 31)) as i32
                } else {
                    v >> ((-s) & 31)
                })
            }
            "%lsh" => {
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
            "%eq?" => {
                need!(2);
                self.bool(a[0] == a[1])
            }
            "%null?" => {
                need!(1);
                self.bool(a[0] == NIL)
            }
            "%fixnum?" => {
                need!(1);
                self.bool(is_fixnum(a[0]))
            }
            "%cons?" => {
                need!(1);
                self.bool(is_cons(a[0]))
            }
            "%symbol?" => {
                need!(1);
                self.bool(self.h.is_symbol(a[0]))
            }
            "%string?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_STRING))
            }
            "%vector?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_VECTOR))
            }
            "%bytes?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_BYTES))
            }
            "%closure?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_CLOSURE) || self.h.is_type(a[0], T_PRIM))
            }
            "%char?" => {
                need!(1);
                self.bool(is_char(a[0]))
            }
            "%float?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_FLOAT))
            }
            "%bignum?" => {
                need!(1);
                self.bool(self.h.is_type(a[0], T_BIGNUM))
            }
            "%object?" => {
                need!(1);
                self.bool(is_obj(a[0]))
            }

            // ---- raw object access ----
            "%alloc-obj" => {
                need!(2);
                self.h.alloc_obj(n!(0) as u32, n!(1) as u32)
            }
            "%obj-type" => {
                need!(1);
                fix(self.h.otype(a[0]) as i32)
            }
            "%obj-len" => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            // The bootstrap interpreter does not check the type the way the
            // machine's instruction does; it is here so that the same source
            // reads on both sides of the bootstrap.
            "%slot" | "%record-ref" => {
                need!(2);
                self.h.slot(a[0], n!(1) as u32)
            }
            "%set-slot!" | "%record-set!" => {
                need!(3);
                let i = n!(1) as u32;
                self.h.set_slot(a[0], i, a[2]);
                a[2]
            }

            // ---- raw memory: the assembler and the kernel live here ----
            "%ld-byte" => {
                need!(1);
                fix(self.h.m.peek8(n!(0) as u32) as i32)
            }
            "%ld-half" => {
                need!(1);
                fix(self.h.m.peek16(n!(0) as u32) as i32)
            }
            "%ld-fixnum" => {
                need!(1);
                let w = self.h.m.peek32(n!(0) as u32);
                fix(w as i32)
            }
            "%st-byte!" => {
                need!(2);
                self.h.m.poke8(n!(0) as u32, n!(1) as u8);
                a[1]
            }
            "%st-half!" => {
                need!(2);
                let addr = n!(0) as u32;
                let v = n!(1) as u32;
                self.h.m.poke8(addr, v as u8);
                self.h.m.poke8(addr + 1, (v >> 8) as u8);
                a[1]
            }
            "%st-fixnum!" => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, n!(1) as u32);
                a[1]
            }
            "%ld32u" => {
                // Read a word as an unsigned value split across two fixnums is
                // overkill; the heap never needs the top bit at build time.
                need!(1);
                fix((self.h.m.peek32(n!(0) as u32) & 0x7fff_ffff) as i32)
            }
            // Read and write a word without retagging, for moving tagged
            // values through raw addresses.
            "%ld-word" => {
                need!(1);
                self.h.m.peek32(n!(0) as u32)
            }
            "%st-word!" => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, a[1]);
                a[1]
            }
            // At build time there is no machine stack to scan, and no
            // collector to scan it; an empty range keeps the shared source
            // honest without pretending otherwise.
            "%stack-pointer" => fix(0),
            "%frame-pointer" => fix(0),
            "%wait-for-input" => NIL,
            "%ecall" => NIL,
            "%sync-cons-run" => NIL,
            "%reload-cons-run" => NIL,
            "%set-context" => NIL,
            "%enable-timer" => NIL,
            "%cycles" => fix(0),
            "%disable" => NIL,
            "%restore-interrupts" => NIL,
            "%enable-after-trap" => NIL,
            "%enable" => NIL,
            "%halt" => {
                bail!("the build tried to halt the machine")
            }
            "%addr-of" => {
                need!(1);
                fix(a[0] as i32)
            }
            "%from-addr" => {
                need!(1);
                n!(0) as u32
            }

            // ---- allocation regions ----
            "%alloc-code" => {
                need!(1);
                fix(self.h.alloc_code(n!(0) as u32) as i32)
            }
            "%alloc-pool" => {
                need!(1);
                fix(self.h.alloc_pool(n!(0) as u32) as i32)
            }
            "%global" => {
                need!(1);
                fix(self.h.m.peek32(n!(0) as u32) as i32)
            }
            "%set-global!" => {
                need!(2);
                self.h.m.poke32(n!(0) as u32, n!(1) as u32);
                a[1]
            }

            // ---- strings, vectors, bytes ----
            "%make-string" => {
                need!(1);
                let n = n!(0) as u32;
                let fillc = if a.len() > 1 { imm_payload(a[1]) as u8 } else { 32 };
                let p = self.h.alloc_obj(T_STRING, n);
                for i in 0..n {
                    self.h.m.poke8(p + i, fillc);
                }
                p
            }
            "%string-length" | "%bytes-length" => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            "%string-ref" => {
                need!(2);
                chr(self.h.m.peek8(a[0] + n!(1) as u32) as u32)
            }
            "%string-set!" => {
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
            "%make-vector" => {
                need!(1);
                let n = n!(0) as u32;
                let fillv = if a.len() > 1 { a[1] } else { NIL };
                let p = self.h.alloc_obj(T_VECTOR, n);
                for i in 0..n {
                    self.h.set_slot(p, i, fillv);
                }
                p
            }
            "%vector-length" => {
                need!(1);
                fix(self.h.olen(a[0]) as i32)
            }
            "%vector-ref" => {
                need!(2);
                let i = n!(1) as u32;
                if i >= self.h.olen(a[0]) {
                    bail!("vector index {i} out of range")
                }
                self.h.slot(a[0], i)
            }
            "%vector-set!" => {
                need!(3);
                let i = n!(1) as u32;
                if i >= self.h.olen(a[0]) {
                    bail!("vector index {i} out of range")
                }
                self.h.set_slot(a[0], i, a[2]);
                a[2]
            }
            "%make-bytes" => {
                need!(1);
                let n = n!(0) as u32;
                let p = self.h.alloc_obj(T_BYTES, n);
                for i in 0..n {
                    self.h.m.poke8(p + i, 0);
                }
                p
            }
            "%bytes-ref" => {
                need!(2);
                fix(self.h.m.peek8(a[0] + n!(1) as u32) as i32)
            }
            "%bytes-set!" => {
                need!(3);
                let off = n!(1) as u32;
                let v = n!(2) as u8;
                self.h.m.poke8(a[0] + off, v);
                a[2]
            }

            // ---- symbols ----
            "%intern" => {
                need!(1);
                let s = self.h.str_of(a[0]);
                self.h.intern(&s)
            }
            "%symbol-name" => {
                need!(1);
                self.h.slot(a[0], SYM_NAME)
            }
            "%symbol-value" => {
                need!(1);
                self.h.slot(a[0], SYM_VALUE)
            }
            // Where a *variable reference* looks, which here is the globals
            // map: a symbol's own cell holds the closure `compile-top` bound
            // for the image, and running that is what "cannot run compiled
            // code at build time" is about. A fluid binding has to land in
            // the world doing the reading, so it uses these two rather than
            // the pair above.
            "%fluid-value" => {
                need!(1);
                match self.get_global(a[0]) {
                    Some(v) => v,
                    None => self.h.slot(a[0], SYM_VALUE),
                }
            }
            "%set-fluid-value!" => {
                need!(2);
                if self.get_global(a[0]).is_some() {
                    self.set_global(a[0], a[1]);
                } else {
                    self.h.set_slot(a[0], SYM_VALUE, a[1]);
                }
                a[1]
            }
            "%set-symbol-value!" => {
                need!(2);
                self.h.set_slot(a[0], SYM_VALUE, a[1]);
                a[1]
            }
            "%symbol-function" => {
                need!(1);
                self.h.slot(a[0], SYM_FUNCTION)
            }
            "%set-symbol-function!" => {
                need!(2);
                self.h.set_slot(a[0], SYM_FUNCTION, a[1]);
                a[1]
            }
            "%symbol-plist" => {
                need!(1);
                self.h.slot(a[0], SYM_PLIST)
            }
            "%set-symbol-plist!" => {
                need!(2);
                self.h.set_slot(a[0], SYM_PLIST, a[1]);
                a[1]
            }
            "%symbol-flags" => {
                need!(1);
                self.h.slot(a[0], SYM_FLAGS)
            }
            "%set-symbol-flags!" => {
                need!(2);
                self.h.set_slot(a[0], SYM_FLAGS, a[1]);
                a[1]
            }
            "%all-symbols" => self.h.g(LG_SYMLIST),
            "%obarray" => self.h.obarray(),

            // ---- characters ----
            "%char->int" => {
                need!(1);
                fix(imm_payload(a[0]) as i32)
            }
            "%int->char" => {
                need!(1);
                chr(n!(0) as u32)
            }

            // ---- closures ----
            "%make-closure" => {
                need!(2);
                // (entry nfree) -> a compiled closure with room for free vars
                let nfree = n!(1) as u32;
                let c = self.h.alloc_obj(T_CLOSURE, 2 + nfree);
                self.h.set_slot(c, CLO_ENTRY, n!(0) as u32);
                c
            }
            "%closure-entry" => {
                need!(1);
                fix(self.h.slot(a[0], CLO_ENTRY) as i32)
            }
            "%apply" => {
                need!(2);
                let args = self.h.list_vec(a[1]);
                return self.apply(a[0], &args);
            }
            "%funcall" => {
                need!(1);
                return self.apply(a[0], &a[1..]);
            }

            // ---- build-time only ----
            "%write" => {
                need!(1);
                print!("{}", self.h.write(a[0]));
                a[0]
            }
            "%display" => {
                need!(1);
                print!("{}", self.h.display(a[0]));
                a[0]
            }
            "%newline" => {
                println!();
                NIL
            }
            "%flush" => {
                use std::io::Write;
                let _ = std::io::stdout().flush();
                NIL
            }
            "%error" => {
                let mut msg = String::new();
                for (i, x) in a.iter().enumerate() {
                    if i > 0 {
                        msg.push(' ');
                    }
                    msg.push_str(&self.h.display(*x));
                }
                bail!("{msg}")
            }
            "%read-file" => {
                need!(1);
                let path = self.h.str_of(a[0]);
                match std::fs::read_to_string(&path) {
                    Ok(t) => self.h.string(&t),
                    Err(e) => bail!("cannot read {path}: {e}"),
                }
            }
            "%load" => {
                need!(1);
                let n = self.h.str_of(a[0]);
                return self.load(&n);
            }
            "%macroexpand-1" => {
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
            "%macro?" => {
                need!(1);
                let m = self.is_macro(a[0]);
                self.bool(m)
            }
            "%gensym" => {
                let n = self.h.g(LG_GCCOUNT);
                self.h.set_g(LG_GCCOUNT, n + 1);
                let nm = format!("g{n}");
                self.h.intern(&nm)
            }
            "%eval" => {
                need!(1);
                return self.eval(a[0], &None);
            }
            "%exit" => {
                let c = if a.is_empty() { 0 } else { n!(0) };
                std::process::exit(c);
            }
            other => bail!("primitive {other} is not implemented"),
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

/// (name, arity hint). The arity hint is documentation; checks happen inline.
pub static PRIMS: &[(&str, u32)] = &[
    ("%cons", 2),
    ("%car", 1),
    ("%cdr", 1),
    ("%set-car!", 2),
    ("%set-cdr!", 2),
    ("%+", 2),
    ("%-", 2),
    ("%*", 2),
    ("%/", 2),
    ("%mod", 2),
    ("%+o", 2),
    ("%-o", 2),
    ("%*o", 2),
    ("%mulhi16", 2),
    ("%rem", 2),
    ("%=", 2),
    ("%<", 2),
    ("%>", 2),
    ("%<=", 2),
    ("%>=", 2),
    ("%logand", 2),
    ("%logior", 2),
    ("%logxor", 2),
    ("%lognot", 1),
    ("%ash", 2),
    ("%lsh", 2),
    ("%eq?", 2),
    ("%null?", 1),
    ("%fixnum?", 1),
    ("%cons?", 1),
    ("%symbol?", 1),
    ("%string?", 1),
    ("%vector?", 1),
    ("%bytes?", 1),
    ("%closure?", 1),
    ("%char?", 1),
    ("%float?", 1),
    ("%bignum?", 1),
    ("%object?", 1),
    ("%alloc-obj", 2),
    ("%obj-type", 1),
    ("%obj-len", 1),
    ("%slot", 2),
    ("%set-slot!", 3),
    ("%record-ref", 2),
    ("%record-set!", 3),
    ("%ld-byte", 1),
    ("%ld-half", 1),
    ("%ld-fixnum", 1),
    ("%st-byte!", 2),
    ("%st-half!", 2),
    ("%st-fixnum!", 2),
    ("%ld32u", 1),
    ("%ld-word", 1),
    ("%st-word!", 2),
    ("%stack-pointer", 0),
    ("%frame-pointer", 0),
    ("%wait-for-input", 0),
    ("%ecall", 1),
    ("%sync-cons-run", 0),
    ("%reload-cons-run", 0),
    ("%set-context", 1),
    ("%enable-timer", 0),
    ("%cycles", 0),
    ("%disable", 0),
    ("%restore-interrupts", 1),
    ("%enable-after-trap", 0),
    ("%enable", 0),
    ("%halt", 1),
    ("%addr-of", 1),
    ("%from-addr", 1),
    ("%alloc-code", 1),
    ("%alloc-pool", 1),
    ("%global", 1),
    ("%set-global!", 2),
    ("%make-string", 1),
    ("%string-length", 1),
    ("%string-ref", 2),
    ("%string-set!", 3),
    ("%make-vector", 1),
    ("%vector-length", 1),
    ("%vector-ref", 2),
    ("%vector-set!", 3),
    ("%make-bytes", 1),
    ("%bytes-length", 1),
    ("%bytes-ref", 2),
    ("%bytes-set!", 3),
    ("%intern", 1),
    ("%symbol-name", 1),
    ("%symbol-value", 1),
    ("%fluid-value", 1),
    ("%set-fluid-value!", 2),
    ("%set-symbol-value!", 2),
    ("%symbol-function", 1),
    ("%set-symbol-function!", 2),
    ("%symbol-plist", 1),
    ("%set-symbol-plist!", 2),
    ("%symbol-flags", 1),
    ("%set-symbol-flags!", 2),
    ("%all-symbols", 0),
    ("%obarray", 0),
    ("%char->int", 1),
    ("%int->char", 1),
    ("%make-closure", 2),
    ("%closure-entry", 1),
    ("%apply", 2),
    ("%funcall", 1),
    ("%write", 1),
    ("%display", 1),
    ("%newline", 0),
    ("%flush", 0),
    ("%error", 1),
    ("%read-file", 1),
    ("%load", 1),
    ("%macroexpand-1", 1),
    ("%macro?", 1),
    ("%gensym", 0),
    ("%eval", 1),
    ("%exit", 0),
];
