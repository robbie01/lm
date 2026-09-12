# Cleanup targets

What is still in the way of a sensible, orthogonal, hackable machine, judged
against the three ancestors: Exec's economy, Genera's uniformity, Go's
plainness. Each item says what is wrong and what the plain version is. Nothing
here is done.

## The language

**Two spellings for everything.** `%car` and `car`, `%+` and `+`, `%eq?` and
`eq?`, `%string-ref` and `string-ref`. The `%` forms are used throughout the
system for speed, but the compiler open-codes the plain names at the same cost
for one or two arguments, so most of the `%` in ordinary code buys nothing and
costs a second vocabulary. The plain version: `%` marks only what is raw
(`%ld-fixnum`, `%slot`, `%sync-cons-run`), every checked operation has one name,
and the compiler folds a three-argument `+` into two instructions rather than
a call. Then gc.lisp, exec.lisp and wb.lisp read like Lisp.

**`if` always spells its else.** `(if c a nil)` is written thousands of times
because one-armed `if` is not allowed; `when` and `unless` exist and are
rarely used. Allow one-armed `if`, or use `when` everywhere and mean it.

**`(if (if a b nil) c nil)` instead of `and`.** `and` and `or` are macros
that do not fuse into a branch, so the collector and kernel nest `if`s by
hand. Teach `emit-test-jump-false` to walk `and` and `or`, then write them.

**Three ways to inline.** `defsubst` (a macro copying the body),
`definline` (an emitter on the symbol's function cell) and
`*inline-aliases*` (a table mapping a plain name to an intrinsic at one
arity). One declaration, on the definition, should say "open-code this".

**Six ways to read a word.** `peek`, `peek-signed`, `peek8`, `%ld-fixnum`,
`%ld-word`, `%ld-half`, with `poke`, `poke8`, `%st-fixnum!`, `%st-word!`,
`%st-half!` beside them. The plain set is `peek`/`poke` by width (8, 16, 32)
with the unsigned reading, `%ld-word`/`%st-word!` for a tagged word, and the
raw fixnum forms only inside the collector.

**Record prefixes are abbreviations.** `(defrecord (task tc) ...)` gives
`tc-state`; likewise `mp`, `mn`, `sv`, `fl`, `is`, `mx`, `cx`, `sb`, `ol`,
`rw`, `bt`, `rp`, `bm`, `sh`, `dv`. Genera would say `task-state`. Default
the prefix to the type name and abbreviate only where a name is long and the
accessors are hot in the source (`win-x` is fine).

**Two output vocabularies.** `emit-str`/`emit-ch` beside `display`/`write`.
The `emit` forms exist so the trap handler and the collector can print
without allocating; application code should not see them.

**`!` is not one rule.** `gfx-colour!`, `disk-interrupts!`, `set-blit-sleep!`
against `int-enable`, `timer-set-in`, `claim-device`, `notify`, `signal`.
Settle it: `!` on a procedure that changes an object it was handed; a plain
verb for an action on the machine.

**The export lists live in one file** because a name has to mean the same
symbol whichever file is read first. They are hand-kept, and lm's is five
hundred names long. A `defpublic` marker on the definition, harvested into
packages.lisp by the build, would keep the single reading order and lose
the maintenance.

**No condition system, no debugger.** The Genera half of the machine is a
prompt with a backtrace. An error should stop the task where it is, keep its
stack, and offer restarts in a window: retry, return a value, abort to the
prompt. The explorer is the start of that window; the missing piece is
keeping the faulting stack alive instead of abandoning it, which means the
report and the restart choice happen in another task.

## The kernel

**A task owns four lists.** Children, mutexes, devices and cleanups are
released by four mechanisms when a task ends (`remove-children`,
`abandon-mutexes`, `release-devices-of`, `run-cleanups`). One "owned
resources" list with a release protocol per kind would be Exec's way, and
would let a driver's port and interrupt server be released the same way.

**Every driver is the same skeleton written four times.** `start`, `running?`,
`serve`, `driver-port`, `*driver*`, the claim, the interrupt server, the
resident registration. A `driver` record in exec that owns the device, the
server task, its port and its interrupt server would reduce disk.lisp to its
vocabulary and the transfer code.

**The trap handler prints.** Fault reports are composed inside the handler,
with interrupts off, by Lisp that allocates out of the interrupted task's run
(`keep-cons-run` exists to make that survivable). The handler should record
the fault and restart the task into a reporter; nothing in the handler
should cons.

**Two console paths.** `uart-string` raw for the collector and the handler,
`console.driver` for everyone else, and `can-ask?` decides per character. A
ring buffer in the pool that the raw path writes and the console task
drains would make one path, with the raw writer usable anywhere.

**Signals 0 to 15 are reserved for nothing.** Three are used (vblank, blit,
mutex). Reserve what is used.

**Timing is missing.** No timed wait, no timeout on a request, no periodic
task. A timer server that hands out signals at deadlines is the one missing
Exec primitive.

## The chips and the workbench

**hw.lisp is five things.** Devices and ownership, the pool allocator, the
interrupt controller, the chip registers, and drawing (bitmaps, rastports,
regions, lines, circles). Drawing belongs in its own package beside
platinum and ui; the chips beside their drivers.

**Two fonts, two APIs.** `draw-text` for Charcoal, `draw-mono` for the
terminal face, with different metrics functions. A font record with one
`draw-string` would make a face a value, and a shell could be set in either.

**wb.lisp is the desktop, the compositor, the input router and the shell.**
Shells are an application and belong in their own file; the compositor and
the window list are the desktop.

**The workbench has no menus and no resize.** The zoom and collapse boxes
are drawn and do nothing, `grow-box` is drawn by nobody, and the only way to
choose the front window is the pointer. ~/platinum has the menu bar and the
outline-drag resize measured already.

**Controls have no focus.** A window's task hands every key to one control.
A focus ring and tab order are the next thing the toolkit needs, then a text
field, then menus.

**Double clicks are counted by frame.** The input chip delivers no click
count, so the outline times clicks by the vertical blank. The chip, or the
driver, should carry it.

## The machine

**The bootstrap interpreter has one namespace.** Two packages the forge runs
interpreted cannot define the same bare name (asm and the compiler collided
on `resolve`). Key the interpreter's globals by symbol with the reader's
package resolution, and the constraint goes.

**Unused instructions.** `fltu`, `ldxbi`, `stxbi`, `fori`, and the trapping
`fmulo` has one customer. Before the SoC is fixed, either use them (`fltu` is
the right compare for addresses) or drop them.

**The `lg-scratch` cells.** Four low-memory words named `scratch0` to
`scratch3` hold, respectively, the task exit closure, a trampoline argument,
nothing, and the trap entry the forge uses. Name each for what it holds.

**The tests live in the demo file.** `numbers`, `words`, `locking`, `talking`,
`blitting`, `devices` and `drivers` are the machine's test suite, written
with `num-check`, and sit in demo.lisp beside the balls. A `check` package
with a counting harness, run by `lmdev` through the machine, would make them
what they are.
