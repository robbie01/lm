;;; packages.lisp - every module, and the names it makes public.
;;;
;;; Read first on both sides of the bootstrap, before any other source, so
;;; that a name means the same thing whichever order the files load in.
;;;
;;; A package is a namespace and nothing more. The reader resolves a bare name
;;; in the current package, then in whatever the packages it uses have
;;; exported, and interns one of its own if neither has it. At run time it is
;;; all symbol objects, so packages cost the machine nothing.
;;;
;;; pkg:name reaches an exported name from outside. pkg::name reaches past the
;;; interface into a package's private names.

;; ---------------------------------------------------------------- modules
;; Every package here is one the machine has. The forge declares one more for
;; itself, `boot`, at the head of boot.lisp: that file is never compiled, so
;; its package is not carried by the image.
(defpackage lm use gc hw exec)                                     ; the prelude
(defpackage gc use lm hw)                                          ; the collector
(defpackage hw use lm)                                             ; the chips
(defpackage asm use lm gc)                                         ; the assembler
(defpackage compiler use lm hw asm sys)                            ; Lisp to RV32
(defpackage sys use lm gc asm compiler exec)                       ; traps, prompt, rebuild
(defpackage exec use lm gc hw asm sys)                             ; the kernel
(defpackage disk use lm hw exec)                                   ; disk.driver
(defpackage input use lm hw exec)                                  ; input.driver
(defpackage gfx use lm hw exec)                                    ; gfx.driver
(defpackage console use lm hw exec)                                ; console.driver
(defpackage snap use lm gc hw sys exec)                            ; saving the machine
(defpackage platinum use lm hw)                                    ; the Mac OS 8/9 appearance
(defpackage wb use lm hw sys exec platinum)                        ; the workbench
(defpackage eyes use lm gc hw exec sys wb platinum)                ; xeyes
(defpackage ui use lm hw exec wb platinum)                        ; controls
(defpackage explorer use lm hw exec sys wb platinum ui)           ; a window onto the heap
(defpackage user use lm gc hw asm compiler sys exec snap wb eyes platinum explorer)  ; where a prompt starts

;; ---------------------------------------------------------------- exports
;; The prelude first: every other list below is read in its own package, and
;; reading `export` there means finding it here. The prelude is a library, so
;; its interface is most of what it defines.
(in-package lm)
(export '(
  alloc-object *object-allocator* *collector* *pacer*
  ;; the generated layout: the names another package reads
  low-end reset-vector reset-reserve cons-base cons-limit obj-base obj-limit gc-bitmap obj-starts obj-starts-ready obj-starts-magic mmio-base
  snap-magic
  lg-bootlist lg-cons-free lg-cons-free-n lg-cons-ptr lg-errhandler lg-gccount lg-obarray
  lg-obj-end lg-obj-free-n lg-obj-ptr lg-package lg-packages
  lg-roots lg-boot-stack lg-trap-stack lg-trap-nest lg-startup lg-symlist lg-task-exit
  lg-toplevel lg-trapdepth lg-trap-entry lg-traphook lg-trapsave lg-traptmp lg-traptmp2
  value-bytes kind-fixnum kind-char kind-unbound kind-pair kind-object
  perm-ld perm-sd perm-lc perm-sc perm-lm perm-ex perm-sr perm-se perm-hd perms-all perms-pair perms-object
  perms-nil
  otype-sentry otype-closure
  obj-bins obj-bin-count t-free t-symbol t-string t-vector t-bytes t-closure t-record t-float
  t-port t-bignum t-code t-text t-stack t-context code-entry code-name code-lits clo-entry clo-code clo-free
  sym-name sym-value sym-function sym-plist sym-flags sym-package sym-macro sym-constant sym-detached pkg-tag
  ctx-slots ctx-bytes reg-pc reg-ra reg-sp reg-gp reg-tp reg-t0 reg-t1 reg-t3 reg-s0 reg-s1 reg-s2
  reg-a0 reg-a7
  ecall-arity ecall-oom ecall-error ecall-reschedule ecall-record
  cause-misaligned-fetch cause-fetch-fault cause-illegal cause-breakpoint
  cause-misaligned-load cause-load-fault cause-misaligned-store cause-store-fault
  cause-ecall cause-wrong-type cause-range cause-overflow cause-divzero cause-run
  cause-barrier cause-stack cause-cap-fetch cause-cap-load cause-cap-store
  refuse-length refuse-tag refuse-seal refuse-load refuse-store
  irq-software irq-timer irq-external
  exit-ok exit-error exit-gc-stack exit-gc-corrupt exit-trap-spiral
  dev-sys dev-uart dev-timer dev-gfx dev-input dev-blit dev-disk
  int-uart int-vblank int-input int-blit int-disk int-soft
  disk-busy disk-refused disk-cmd-read disk-cmd-write disk-cmd-flush
  blit-list-reg blit-status-reg blit-ctrl-reg blit-status-busy blit-status-refused blit-list-size
  bl-src bl-dst bl-next bl-w bl-h bl-smod bl-dmod bl-val bl-op bl-x0 bl-y0 bl-x1 bl-y1 bl-status
  blit-done blit-pending blit-refused-src blit-refused-dst
  op-copy op-fill op-line
  ;; the primitives
  %* %+ %- %/ %< %<= %= %> %>= %addr-of %apply %ash
  %bit-ref %bit-set! %min %max %popcount
  %bytes-length %bytes-ref %bytes-set! %bytes? %car %cdr %char->int %char?
  %closure? %cons %cons? %cycles %disable %display %ecall
  %bignum? %enable %enable-interrupt-lines %eq? %error %eval %fixnum? %float? %flush
  %fluid-value %set-fluid-value!
  %from-addr %funcall %gensym %halt %this-task %set-this-task! %int->char
  %set-stack-limit! %stack-limit %set-gc-mode! %context
  %intern %ld-half %ld-byte %logand %logior %lognot %logxor %lsh %macro?
  %*o %+o %-o
  %macroexpand-1 %make-bytes %make-string %make-vector %mod %newline %null?
  %obj-len %obj-type %object? %ld-word %st-word! %ld-cap %st-cap! %read-file
  %enable-after-trap %record? %record-ref %record-set!
  %cons-run %set-cons-run! %rem %restore-interrupts %set-car! %set-cdr!
  %set-context!
  %set-slot! %set-symbol-flags! %set-symbol-function!
  %set-symbol-plist! %set-symbol-value! %slot %st-half! %st-byte!
  %stack-pointer %string-length %string-ref %string-set! %string?
  %symbol-flags %symbol-function %symbol-name %symbol-plist %symbol-value
  %symbol? %vector-length %vector-ref %vector-set!
  %vector? %wait-for-interrupt %write
  ;; capabilities
  %root %cap-ld %cap-st! %cap-ld-word %cap-st-word! %cap-ld-byte %cap-st-byte!
  %cap-base %cap-len %cap-top %cap-perms %cap-otype %cap-offset %cap-tag? %cap-sealed? %cap-high
  %cap-set-addr %cap-inc %cap-bounds %cap-bounds-exact %cap-and-perms %cap-clear-tag %cap-seal-entry
  %cap-seal-closure %cap-seal %cap-unseal %cap-unseal-within %cap-set-high %cap=? %cap-subset?
  %rrl %ram
  ;; the language and the library
  &optional &rest * *gensym-count* *in*
  *out* %unbound *await* + - / /= 1+ 1- < <= = > >= abs add2 alist->table
  all-packages and any append append-map append2 apply apply-list ash
  assert assoc assq atom? await-char begin bit-set? boolean? bytes-length
  bytes-ref bytes-set! bytes? caadr caar cadddr caddr cadr car case cdadr
  cdar cdddr cddr cdr chain2 char->integer char-alphabetic? char-downcase
  char-numeric? char-upcase char-whitespace? char<? char=? char>? char?
  code-object? comment compose cond cons serial-stream constantly
  current-package current-stream cycles decf defconstant define
  define-values defmacro defsubst fluid-let bind-fluid! unbind-fluid! task-binds
  set-task-binds! swap-binds-in! swap-binds-out! place-value set-place-value!
  unwind-binds-to!
  *binds-get* *binds-set* *boot-binds* defpackage defparameter defun defvar delq
  defrecord record-shape record-shape! record-forms record-field record-tag
  set-record-field! record-fault shape-prefix shape-open? shape-fields word?
  *record-shapes* *record-inline-hook*
  unsafe unsafe-file unsafe-names symbol-unsafe?
  digit->int display display-to-string do dolist dotimes else emit-ch
  emit-code-label emit-name emit-str eq-hash eq? equal? eqv? error even?
  clamp isqrt
  every export export-symbol! expt filter find-package find-symbol-in
  find-visible first fixnum? fold fold-right for-each funcall function? gcd
  gensym gensym-1 get get-char identity if if-let in-package incf
  integer->char intern intern-in intern-string intern-visible iota lambda
  last last-pair length let let* letrec list list* list->string
  list->vector list-copy list-index list-ref list? logand logior lognot
  logxor loop lsh make-bytes make-bytes-n make-closure open-closure make-list
  make-package make-record make-stream make-string make-string-n make-symbol make-table
  make-vector make-vector-n map map2 mapcar max max2 member memq merge2 min
  min2 mod modulo mul2 neg negative? newline not nth nthcdr null? num-eq
  num-ge num-gt num-le num-lt number->hex number->string number->string-fix number?
  object-payload byte-payload? odd? or out-char out-of-memory *names-seen* package package-name
  package-use package? pair? pop position positive? princ print print-list
  print-obj print-record print-symbol print-vector print-function print-capability
  emit-cap-summary cap-top-hex cap-top-saturated?
  push put qualified-hash
  quasiquote quote quotient reduce rem remainder remove-if rest revappend
  read-char-or-nil read-form read-toplevel read-forms-from-string read-from-string
  peek-char wait-char skip-space string-stream with-input-from-string
  *peeked* *eof-ok* *reader-eof* start-reading-string stop-reading read-next
  act-on-package-form form-head-named?
  set-package-by-name define-package-by-name package-designator
  remove-eq resolve-function reverse second set! set-car! set-cdr! set-current-package!
  set-package-use! set-symbol-function! set-symbol-value! setf sort space
  stream-get stream-put stream-await stream? string string->list string->number
  string->symbol string-append string-downcase string-hash string-index
  string-length string-ref string-set! string-upcase string<? string=?
  string? sub2 substring symbol->string symbol-exported?
  symbol-flags symbol-function symbol-index symbol-name
  symbol-package symbol-plist symbol-value symbol? t table->alist
  table-capacity table-count table-del! table-for-each table-has?
  table-keys table-ref table-set! table? third time uart-char
  uart-ctrl uart-data uart-hex uart-nl uart-num uart-string
  undefined-globals unless unquote unquote-splicing use-stream! vector
  vector->list vector-equal? vector-fill! vector-grow vector-length
  vector-map vector-ref vector-set! vector? warn when when-let while
  wrap+ wrap- wrap* strict+ strict- strict* sat+ sat- sat*
  saturate fixnum-only most-positive-fixnum most-negative-fixnum
  without-interrupts
  with-output-to-string write write-char-name write-string-quoted
  write-to-string zero?
  ;; ---- bignums ----
  bignum? bignum-even? bignum->string bn-two-to generic-ash bn-alloc bn-alloc-halves bn-finish bn-halves
  bn-limbs bn-limb bn-set-limb! bn-of bn-shrink bn-sign
  generic-add generic-cmp generic-divmod generic-mul generic-neg
  generic-quotient generic-remainder generic-sub generic-zero?
  mag-add! mag-cmp mag-div-small! mag-divmod! mag-half mag-mul! mag-set!
  mag-shl1! mag-sig mag-sub! num-mag-cmp num-sign
))

(in-package gc)
(export '(
  forget-unused-packages
  gc collect extra-roots collect-for-image
  invalidate-runs note-run! take-owed-run
  scan-context drop-context-run empty-cons-run install-allocator
  refill-cons-run code-object-at code-bytes object-bytes-used gc-scratch room
  barrier busy? step ensure-starts
))

(in-package hw)
(export '(
  bm-pixels bitmap? make-bitmap alloc-bitmap
  blit-busy? blit-drain blit-sync blit-wait-descriptor blit-wait-ring
  device-page device-page-bytes
  disk-go disk-status disk-busy? disk-blocks disk-interrupts!
  *blit-ring* *gc-blit-ring* *in-interrupt*
  blit-descriptor gc-blit-descriptor ensure-gc-blit-ring blit-go
  *screen* bm-blit-rect bm-fill-rect
  bm-plot bm-point bm-index bm-w bm-h
  make-bitmap-rastport make-rastport-on rp-bitmap
  blit-rect
  draw-circle draw-line
  *screen-rp* screen-rastport rastport?
  rp-origin-x rp-origin-y rp-region
  set-rp-origin! set-rp-region!
  rect rect-x rect-y rect-w rect-h rect-x2 rect-y2
  rect-intersect rect-contains? rect-subtract region-subtract-rect region-area
  region-intersect-rect region-subtract
  fill-circle check-colour
  fill-rect
  rgb
  int-ack int-disable int-enable int-pending int-raise millis timer-hz
  peek peek8 plot poke poke8
  input-take input-inject input-interrupts! input-buttons input-mods
  random screen-height
  screen-width
  timer-never timer-set-in
  gfx-show gfx-colour! gfx-vblank-irq! gfx-present!
  serial-interrupts!
  blit-irq-each! blit-done? blit-refused? blit-clear-refused! set-blit-sleep! interrupts-on?
))

(in-package asm)
(export '(
  $a0 $a1 $a2 $a3 $a4 $a5 $a6 $a7 $gp $ra $s0 $s1 $s2 $sp $t0 $t1 $t2 $t3 $t4
  $t5 $t6 $tp $zero
  ;; s3..s11 are where a leaf function keeps its locals.
  $s3 $s4 $s5 $s6 $s7 $s8 $s9 $s10 $s11
  ;; the assembler and placing its code
  make-assembler asm-buf asm-len asm-labels asm-fixups asm-origin asm-nlits
  asm-privileged set-asm-len! set-asm-origin! set-asm-privileged!
  label label-offset gensym-label literal literal-offset place place-at code-object
  ;; CSRs, and the opcodes a trap handler decodes
  csr-cycle csr-cycleh csr-ddc csr-gcmode csr-mcause csr-mepc csr-mie csr-mip
  csr-mscratch csr-mstatus csr-mtidc csr-mtval csr-mtvec csr-stklim csr-utidc
  op-load op-store op-jal op-jalr op-sys op-rvy op-xlm
  ;; RV32IMC
  i-add i-addi i-addi-w i-and i-andi i-auipc i-beq i-beqz i-bge i-bgeu i-bgt
  i-ble i-blt i-bltu i-bne i-bnez i-branch i-call-reg i-csrrc i-csrrci
  i-csrrs i-csrrsi i-csrrw i-csrrwi i-div i-divu i-ebreak i-ecall i-j i-jal
  i-jalr i-jr i-la i-lb i-lbu i-lh i-lhu i-li i-lui i-lw i-mret i-mul
  i-mulh i-mulhsu i-mulhu i-mv i-neg i-nop i-not i-or i-ori i-rem i-remu
  i-ret i-sb i-seqz i-sh i-sll i-slli i-slt i-slti i-sltiu i-sltu i-snez
  i-sra i-srai i-srl i-srli i-sub i-sw i-wfi i-xor i-xori
  i-lw-abs i-ly-abs i-sw-abs i-sy-abs
  ;; the B extension and Zicond
  i-andn i-bclr i-bclri i-bext i-bexti i-binv i-binvi i-bset i-bseti
  i-clz i-cpop i-ctz i-czero-eqz i-czero-nez i-max i-maxu i-min i-minu
  i-orcb i-orn i-rev8 i-rol i-ror i-rori i-sextb i-sexth i-sh1add i-sh2add
  i-sh3add i-xnor i-zexth
  ;; RVY
  i-ly i-sy i-yadd i-yaddi i-yaddi-w i-yaddrw i-yamask i-ybaser i-ybld
  i-ybndsrw i-ybndsw i-ybndswi i-yeq i-yhir i-yhiw i-ylenr i-ymv i-ypermc
  i-ypermr i-yseale i-ysealt i-ysh1add i-ysh2add i-ysh3add i-yss i-ytagr
  i-ytopr i-ytyper i-yunseals i-yunsealt
  ;; Xlm
  i-beqx i-bnex i-car i-cdr i-jcl i-lhdr i-lref i-lvar i-npair i-sealcl
  i-set-car i-set-cdr i-sref i-vkind
  i-ldx i-ldxb i-ldxbi i-ldxi i-stx i-stxb i-stxbi i-stxi
  i-fadd i-faddi i-faddio i-faddo i-fand i-fandi i-fdiv i-feq i-flt i-fltu
  i-fmul i-fmulo i-for i-fori i-frem i-fshi i-fsll i-fsra i-fsrl i-fsub
  i-fsubo i-fxor i-retag
  i-lb-ddc i-lbu-ddc i-lh-ddc i-lhu-ddc i-lw-ddc i-ly-ddc
  i-sb-ddc i-sh-ddc i-sw-ddc i-sy-ddc
))

(in-package compiler)
(export '(
  *boot-thunks* *image* add-boot-thunk compile-function
  compile-top setup-intrinsics
))

(in-package sys)
(export '(
  *abort-cleanup-fn* *repl-restart* *resume-fn* *return-addr-fn* *stack-top-fn*
  *task-abort-fn*
  bye compile-time-eval error-trap eval expand-macro handle-trap
  kickstart macro-form?
  rebuild rebuild-end genesis *fresh-image* record-initialiser register-macro repl
  resume-kickstart print-report
  ctx-set! enter-closure
  system-name top-level-form
))

(in-package exec)
(export '(
  add-task cause exec-init exec-start
  ;; handle-interrupt and switch-tasks are called by the trap handler in sys.
  handle-interrupt switch-tasks
  ;; ---- shared data ----
  make-mutex mutex-lock mutex-unlock with-mutex mutex-hand-over
  mutex-owner mutex-name mutex? task-alive?
  ;; what `mutex-lock` answers instead of `t` when the last owner ended holding it
  abandoned
  preemption-off preemption-on
  task-snapshot task?
  this-task
  remove-task reschedule sigf-vblank signal sigf-blit
  ;; ---- talking between tasks ----
  make-port make-port-for delete-port
  make-message message-body set-message-body! delete-message
  put-message get-message wait-port reply-message port-ready? wait-ports notify
  sleep wait-timeout now-ms
  request send make-server server-port server-task server-running?
  spawn task-children task-parent remove-children
  reply-port
  node-name node-pri find-name find-task list-nodes
  *vblank-count* wait-vblank
  task-count tasks wait
  ;; ---- when things go wrong, and drivers ----
  failure? failure-why make-failure fail-message port-signal port-open? server-poll!
  on-task-end detach-task add-resident
  make-interrupt add-int-server remove-int-server
))

(in-package disk)
(export '(
  read-blocks write-blocks flush size exclusive write-raw
  start running? *driver* *sleeps*
))

(in-package input)
(export '(
  ;; The words an event is made of. Exported so that `key` read in another
  ;; package is this symbol.
  key mouse button wheel down up moved
  listen unlisten next-event inject
  mouse-x mouse-y mouse-buttons
  start running? *driver*
))

(in-package gfx)
(export '(
  open-screen attach-screen set-colour set-colours screen-sync vblank-count
  start running? *driver* *sleeps*
))

(in-package console)
(export '(
  open start running? *driver*
))

(in-package snap)
(export '(
  save-image save-fresh
))

(in-package platinum)
(export '(
  palette palette-base grey black white
  g1 g2 g3 g4 g5 g6 g7 g8 g9 g10 g11 g12 g13
  lav lav-light lav-dark lav-darkest desktop desktop-dark
  title-height band box-size box-x box-y menubar-height menubar-first-x
  hline vline frame-rect raised sunken stripes title-box
))

(in-package wb)
(export '(
  *windows* front-window make-window new-shell
  window-rastport update damage present window-bitmap
  window-damage window-damage-rect window-rect composite
  button-down drag repaint win-data
  win-inner-h win-inner-w win-inner-x win-inner-y win-refresh
  win-task window-close window-open set-win-data! set-win-refresh! set-win-task!
  win-h win-w win-x win-y workbench win-bm resume
  win-port set-win-port! window-send window-event window-wait-event key-event?
  text-width text-truncate draw-text draw-char
  make-demo-window win-plot win-point win-fill win-row window-footprint
  draw-mono-char mono-advance mono-height
))

(in-package eyes)
(export '(
  eyes eyes? make-eyes look-at
  eyes-window eyes-rad eyes-look-x eyes-look-y
  set-eyes-look-x! set-eyes-look-y! set-eyes-rad!
))

(in-package ui)
(export '(
  row-height scrollbar-width changed
  make-scrollbar scrollbar-range! scrollbar-set! draw-scrollbar scrollbar-event
  sb-value sb-max
  make-button draw-button button-event bt-label set-bt-label!
  make-outline draw-outline outline-event outline-selected expand! collapse! toggle!
  ol-roots ol-selected rw-object rw-label rw-depth rw-expanded rw-children
  triangle scroll-arrow
))

(in-package explorer)
(export '(
  explorer explore brief parts has-parts?
))

;; A prompt starts here.

(in-package user)
