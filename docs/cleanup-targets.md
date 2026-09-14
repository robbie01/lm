# Cleanup targets

What was in the way of a sensible, orthogonal, hackable machine, judged
against the three ancestors: Exec's economy, Genera's uniformity, Go's
plainness. Every item now carries a verdict. **RESOLVED** means it is done,
or was found to be already true of the tree, or the item was mistaken.
**WONTFIX** means it was weighed and decided against, and says why; where
something would reopen it, the trigger is named. The memory-safety side of
the language is in [memory-safety.md](memory-safety.md).

## The language

**Two spellings for everything. WONTFIX.** `%car` and `car`, `%+` and `+`.
The premise, that `%` buys speed the compiler gives the plain name anyway,
is wrong in the places that matter. `%+` wraps; `+` traps and widens to a
bignum. The test-position fusions, the constant-operand folds and the
immediate-index forms are keyed on the `%` names. The bootstrap interpreter
knows 130 `%` primitives and no plain ones, so the prelude and the three
files the forge interprets have no choice. So the two vocabularies are the
checked language and the raw one, and the `%` is the mark that says which.
That mark is worth keeping, and worth enforcing: see memory-safety.md.
*Trigger:* if a plain `(< i n)` in a test position ever shows in a profile,
the fusable set can take the plain comparison names in about ten lines.

**`if` always spells its else. RESOLVED.** It never had to. `compile-if`
and the interpreter both read a missing else as nil, and `when` and
`unless` exist. The eleven hundred `nil` arms are a habit, not a rule, and
are left where they are rather than rewriting every file for no gain.

**`(if (if a b nil) c nil)` instead of `and`. RESOLVED.** The compiler now
walks an `if` in a test position: `emit-if-test-jump-false` turns each arm's
test into its own branch, so `and`, `or` and the kernel's hand-nested forms
all compile to jumps without building a value. Write `and` and `or`.

**Three ways to inline. WONTFIX.** They are three different things.
`definline` is the table of instruction emitters and has no Lisp body to
hang a declaration on; `*inline-aliases*` maps a checked name onto one of
them; `defsubst` copies a Lisp body and has 27 uses, all raw bit-twiddling
in the collector and the bignums. `defrecord` already is the one
declaration on the definition that says open-code this.

**Six ways to read a word. WONTFIX**, with one repair. `peek`/`poke` are
the checked, widening pair for everyone: a critical section, a bounce
through `lg-raw-word`, a bignum for a word with the top bit set. The `%ld-*`
and `%st-*` forms are the raw ones, a single instruction that checks only
that the address is a fixnum, for the collector and the chips where the
word is known. Two sets, named for what they check, is the irreducible
number. `setter-form` referred to `peek16` and `peek32`, which never
existed; it now writes through `poke` and `poke8` and the raw stores.

**Record prefixes are abbreviations. WONTFIX.** The abbreviated ones are
the hot ones: `cx-` has 207 accessor sites, `win-` 167, `bm-` 89, `tc-` 65,
which is the exemption the item itself grants. The doc's list was also off:
`node` is already `node-succ`, and `tbl`, `asm` and `list` were missing.
Nine hundred and fifty renames, each with a matching export, for no
mechanical effect.

**Two output vocabularies. WONTFIX.** The stated rationale, that `emit-str`
exists so the handler and collector can print without allocating, does not
hold: printing a number allocates on either path, and for a string
`emit-str` and `display` are the same code. `emit-str` is the printer's own
primitive; the 31 uses in demo.lisp are harmless.

**`!` is not one rule. WONTFIX.** The rule as written puts `signal`,
`notify`, `claim-device` and `release-device` on the `!` side, which would
rename the kernel's central verbs for a convention with no mechanical
consequence. The rule as used: `!` marks a mutator of a Lisp object; an
action on the machine is a verb. `gfx-colour!` and `disk-interrupts!` are
the exceptions and can stay exceptions.

**The export lists live in one file. WONTFIX.** A `defpublic` marker cannot
be read and then harvested, because reading is the thing that needs the
answer: a bare name is resolved against the exports at read time, so the
list must exist before the first source is read. The build would need a
textual scraper in Rust, which moves a hand-kept list into a hand-written
parser. The list is 1,363 names, and `*names-seen*` already answers which
of them a build actually used.

**No condition system, no debugger. WONTFIX**, as design. An error abandons
its stack; the report is composed in the handler and printed by the
restart; a mutex held on the abandoned stack is handed on marked
abandoned. Keeping the faulting stack alive means a third task list for
the collector to scan, a reaper that must not free it, an inverse of
`enter-closure` to resume it, a window to choose from, and a pool that
fills with 64 KiB corpses nobody dismissed. `ts-except` is reserved for the
day. *Trigger:* a prompt in a window wanting retry.

## The kernel

**A task owns four lists. WONTFIX.** The order in `remove-task` is
load-bearing and written down there: mutexes and devices go back before
the cleanups run, because a cleanup may want the very thing; ports are
failed after the removed mark, because `put-message` races the same mark;
children are recursive. One uniform list loses the order. `on-task-end` is
already the generic protocol, and every driver uses it for its interrupt
server.

**Every driver is the same skeleton written four times. WONTFIX.** The four
`start`s differ in exactly the details that matter: the disk enables its
chip before claiming it, the display installs the blit sleeper, the
console resets its reader, and each order has a resume-correctness comment
attached. The record that unified them would carry seven hooks, three with
one user each, and be longer than the thirty lines it removed from each.

**The trap handler prints. WONTFIX.** Arithmetic widening allocates in the
handler by design, and that is the hot nested trap; `keep-cons-run` exists
for it and the report composer rides on the same provision. The report is
already printed outside the handler by the restarted task. *Trigger:* a
fault report failing for want of cons space.

**Two console paths. WONTFIX.** The panic paths, `trap-spiral` and
`out-of-memory`, halt the machine right after they print, so a synchronous
register writer has to exist whatever else does; a ring would add a third
path, not replace one. `can-ask?` is the right question, asked in the
right place.

**Signals 0 to 15 are reserved for nothing. RESOLVED.** Four bits are
fixed, vblank, blit, mutex and timer, and `sig-reserved` names them; every
other bit from 0 to 29 is allocated.

**Timing is missing. RESOLVED.** `sleep` and `wait-timeout`, on a deadline
list the timer interrupt walks every quantum.

## The chips and the workbench

**hw.lisp is five things. WONTFIX.** Drawing is 518 of its 905 lines and is
itself eight sections; the pool is used by both hw and exec, in both
directions; a split needs three packages, a change to every `use` line, and
a load order that keeps the pool before exec. The section headers do the
job the packages would. *Trigger:* a second consumer of the drawing code
that does not want the chips.

**Two fonts, two APIs. WONTFIX**, with the dead half removed. Charcoal is a
proportional face with bearing and ink tables; the terminal face is a 6 by
12 cell. A shell's grid is the cell metrics, so a proportional face could
never back it, and "a shell could be set in either" was never true. The
string API of the terminal face, `draw-mono` and `mono-width`, had no
callers and is gone; the shell draws by the cell.

**wb.lisp is the desktop, the compositor, the input router and the shell.
WONTFIX.** The compositor, the window list and the router are already
separate sections; only the shell is foreign, and moving it makes a
package cycle, since `workbench` and `help` both call `new-shell`.

**The workbench has no menus and no resize. WONTFIX**, with the dead code
removed. `grow-box` had no caller and is deleted. The collapse box is not
drawn, contrary to the item; the zoom box is drawn and starts a drag. A
resize needs a size-changed event the window vocabulary lacks, and a
reallocation of both bitmaps; menus need a toolkit that item says does not
exist yet. *Trigger:* an application that needs a second window size.

**Controls have no focus. WONTFIX.** One control is in use, the outline,
and no window has two. *Trigger:* a text field.

**Double clicks are counted by frame. WONTFIX.** The pointer event word is
full, so the chip cannot carry a count without a second word or a stale
register. The frame count is deterministic, which is what a test wants.
When a user wants a wall-clock interval, `millis` is available to the
driver and it is ten lines there.

## The machine

**The bootstrap interpreter has one namespace. RESOLVED.** There is no live
collision: the `resolve` one was renamed away, and the three names defined
twice, `interrupts-on?`, `extra-roots`, `invalidate-runs`, are stubs that
exec replaces through `use`, one symbol each. The constraint stands and is
written here: a package the forge interprets may not define a bare name
another one does.

**Unused instructions. WONTFIX**, as keep. `fori` is emitted by
`emit-or-const`, so the item was wrong about it. `fltu`, `ldxbi` and
`stxbi` are tested encodings that cost nothing at run time; `ldxbi` and
`stxbi` are also the two free slots in custom-1 where a tagged half-word
load and store would go if `%ld-half` ever matters, which is the collector's
run-skipping test.

**The `lg-scratch` cells. RESOLVED.** They are `lg-task-exit`,
`lg-trap-entry`, `lg-boot-arg` and `lg-raw-word`, at the same addresses.
`scratch3` had two unrelated jobs, the forge's trap entry and `peek`'s
staging word; they are two cells now, the second taking the one that was
empty.

**The tests live in the demo file. RESOLVED.** `num-check` counts; `(check)`
runs every suite and halts the machine with the verdict as its exit code;
`lmdev check` boots an image headless with a scratch disk and types it;
`lmdev all` includes it. The suites stay in demo.lisp: they need the
drivers, the screen and the kernel, so they run on the machine and not in
the forge, and they need the reach into every package that `user` has.
