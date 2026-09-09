;;; packages.lisp - every module, and the names it makes public.
;;;
;;; Read first on both sides of the bootstrap, before any source, so that a
;;; name means the same thing whichever order the files are loaded in - and
;;; the two orders do differ, because the forge needs some things earlier
;;; than the machine does.
;;;
;;; A package is a namespace and nothing more. The reader resolves a bare
;;; name in the current package, then in whatever the packages it uses have
;;; exported, and interns one of its own if neither has it. Nothing at run
;;; time knows a package exists - by then it is all symbol objects, which is
;;; why this costs the machine not one instruction.
;;;
;;; pkg:name reaches an exported name from outside. pkg::name reaches past
;;; the interface into a package private business, and says so.

;; ---------------------------------------------------------------- modules
;; Every package here is one the machine has. The forge declares one more for
;; itself - `boot`, at the head of boot.lisp, for the stubs it assembles - and
;; that one is not written here, because this file is compiled into the image
;; and a package declared in it is a package the image carries.
(defpackage lm use gc hw exec)                                     ; the prelude: everything a program is expected to have to hand
(defpackage gc use lm hw)                                          ; the collector
(defpackage hw use lm)                                             ; the custom chips
(defpackage asm use lm gc)                                         ; the assembler
(defpackage compiler use lm hw asm sys)                            ; Lisp to native RISC-V
(defpackage sys use lm gc asm compiler exec)                       ; the kickstart: traps, reader, prompt
(defpackage exec use lm gc hw asm sys)                             ; the kernel: tasks, signals, ports, libraries
(defpackage snap use lm gc hw sys exec)                            ; saving the machine
(defpackage wb use lm hw sys exec)                                 ; the workbench: windows and shells
(defpackage eyes use lm gc hw exec sys wb)                         ; xeyes, one instance per pair
(defpackage user use lm gc hw asm compiler sys exec snap wb eyes)  ; where a prompt starts, and the demos

;; ---------------------------------------------------------------- exports
;; The prelude goes first: every other list below is read in the package it
;; belongs to, and reading `export` there means finding it here.
(in-package lm)
;; 541 public, out of 474 definitions plus the primitives and the special
;; forms. The prelude is a library, so its interface is the library.
(export '(
  alloc-object *object-allocator* *collector*
  ;; the memory map and object layout, generated from the Rust side
  clo-code clo-entry clo-free code-base code-lits code-name cons-base cons-limit dev-blit dev-disk dev-gfx dev-input dev-sys dev-timer dev-uart fast-base imm-unbound int-input int-soft int-vblank lg-bootlist lg-code-end lg-code-free lg-code-free-n lg-code-ptr lg-code-reg lg-code-reg-n lg-cons-free lg-cons-free-n lg-cons-ptr lg-cons-run lg-cons-run-end lg-errhandler lg-gccount lg-gchook lg-imgentry lg-obarray lg-obj-end lg-obj-free-n lg-obj-ptr lg-package lg-packages lg-pool-free lg-poolend lg-poolptr lg-refill lg-roots lg-scratch0 lg-scratch1 lg-stackbot lg-stacktop lg-startup lg-stub-hi lg-stub-lo lg-symcount lg-symlist lg-sysbase lg-toplevel lg-traphook lg-trapsave mmio-base obj-base obj-bins obj-bin-count obj-limit pkg-name pkg-slots pkg-tag pkg-use pool-base pool-limit sym-exported sym-flags sym-function sym-macro sym-name sym-package sym-plist sym-slots sym-value sysbase-ptr t-bytes t-closure t-code t-float t-free t-record t-string t-symbol t-vector
  %* %+ %- %/ %< %<= %= %> %>= %addr-of %alloc-code %alloc-pool %apply %ash
  %bit-ref %bit-set! %min %max %popcount
  %bytes-length %bytes-ref %bytes-set! %bytes? %car %cdr %char->int %char?
  %closure? %cons %cons? %ctest-entry %cycles %disable %display %dv %ecall
  %enable %enable-timer %eq? %error %eval %fixnum? %float? %flush
  %frame-pointer %from-addr %funcall %gensym %global %halt %instance %set-instance! %int->char
  %intern %ld16 %ld32 %ld8 %logand %logior %lognot %logxor %lsh %macro?
  %macroexpand-1 %make-bytes %make-string %make-vector %mod %newline %null?
  %obj-len %obj-type %object? %raw-ld %raw-st! %read-file
  %enable-after-trap %record? %reload-cons-run %rem %restore-interrupts %set-car! %set-cdr!
  %set-context
  %set-global! %set-slot! %set-symbol-flags! %set-symbol-function!
  %set-symbol-plist! %set-symbol-value! %slot %st16! %st32! %st8!
  %stack-pointer %string-length %string-ref %string-set! %string?
  %symbol-flags %symbol-function %symbol-name %symbol-plist %symbol-value
  %symbol? %sync-cons-run %t0 %v %vector-length %vector-ref %vector-set!
  %vector? %wait-for-input %write &optional &rest * *gensym-count* *in*
  *out* *unbound* *wait* + - / /= 1+ 1- < <= = > >= abs add2 alist->table
  all-packages and any append append-map append2 apply apply-list ash
  assert assoc assq atom? await-char begin bit-set? boolean? bytes-length
  bytes-ref bytes-set! bytes? caadr caar cadddr caddr cadr car case cdadr
  cdar cdddr cddr cdr chain2 char->integer char-alphabetic? char-downcase
  char-numeric? char-upcase char-whitespace? char<? char=? char>? char?
  code-object? comment compose cond cons console-stream constantly
  current-package current-stream cycles decf defconstant define
  define-values definstance defmacro defpackage defparameter defun defvar delq
  with-instance
  digit->int display display-to-string do dolist dotimes else emit-ch
  emit-code-label emit-name emit-str eq-hash eq? equal? eqv? error even?
  every export export-symbol! expt filter find-package find-symbol-in
  find-visible first fixnum? fold fold-right for-each funcall function? gcd
  gensym gensym-1 get get-char identity if if-let in-package incf
  integer->char intern intern-in intern-string intern-visible iota lambda
  last last-pair length let let* letrec list list* list->string
  list->vector list-copy list-index list-ref list? logand logior lognot
  logxor loop lsh make-bytes make-bytes-n make-closure make-list
  make-package make-record make-stream make-string make-string-n make-table
  make-vector make-vector-n map map2 mapcar max max2 member memq merge2 min
  min2 mod modulo mul2 neg negative? newline not nth nthcdr null? num-eq
  num-ge num-gt num-le num-lt number->hex number->string number?
  object-payload odd? or out-char out-of-memory package package-name
  package-use package? pair? pop position positive? princ print print-list
  print-obj print-record print-symbol print-vector push put qualified-hash
  quasiquote quote quotient reduce rem remainder remove-if rest revappend
  read-char-or-nil read-form read-forms-from-string read-from-string
  peek-char wait-char skip-space string-stream with-input-from-string
  *peeked* *eof-ok* *reader-eof* start-reading-string stop-reading read-next
  act-on-package-form form-head-named?
  set-package-by-name define-package-by-name package-designator
  remove-eq reverse second set! set-car! set-cdr! set-current-package!
  set-package-use! set-symbol-function! set-symbol-value! setf sort space
  stream-get stream-put stream-wait string string->list string->number
  string->symbol string-append string-downcase string-hash string-index
  string-length string-ref string-set! string-upcase string<? string=?
  string? sub2 substring symbol->string symbol-count symbol-exported?
  symbol-flags symbol-function symbol-hash symbol-index symbol-name
  symbol-package symbol-plist symbol-value symbol? t table->alist
  table-capacity table-count table-del! table-for-each table-has?
  table-keys table-ref table-set! table? third time uart-char uart-count
  uart-ctrl uart-data uart-get uart-hex uart-hex-raw uart-nl uart-num
  uart-num-raw uart-put uart-ready? uart-status uart-string
  undefined-globals unless unquote unquote-splicing use-stream! vector
  vector->list vector-equal? vector-fill! vector-grow vector-length
  vector-map vector-ref vector-set! vector? warn when when-let while
  without-interrupts
  with-output-to-string write write-char-name write-string-quoted
  write-to-string zero?
))

(in-package gc)
;; 24 public, out of 107 definitions.
(export '(
  alloc-code alloc-object forget-package forget-unused-packages frame-ok?
  cons-chunk gc gc-blank-free-objects gc-collect gc-extra-roots gc-for-image
  gc-invalidate-runs
  gc-slot
  gc-scan-conservative gc-scan-frames in-stub? install-allocator obj-take
  refill-cons register-code room stub-args-off stub-frame-size
  stub-mask-off stub-raw-off
))

(in-package hw)
;; 83 public, out of 165 definitions.
(export '(
  *screen* *screen-h* *screen-w* alloc-pool bm-blit-rect bm-clip bm-fill-rect
  bm-plot bm-point make-bitmap-rastport make-rastport-on rp-bitmap
  rp-bitmap-h rp-bitmap-w set-rp-bitmap! blit-rect blt-dmod blt-dst blt-val op-fill
  blt-h blt-op blt-smod blt-src blt-w clamp clear-screen disk-write
  draw-circle draw-line ev-buttondown ev-buttonup ev-keydown ev-mousemove
  *rp* make-rastport rastport? rp-origin-x rp-origin-y rp-region
  set-rp-origin! set-rp-region! use-rastport screen-fill-rect screen-plot
  screen-blit-rect rect rect-x rect-y rect-w rect-h rect-x2 rect-y2 rect-ok?
  rect-intersect rect-contains? rect-subtract region-subtract-rect region-area
  region-intersect-rect region-subtract
  event-ascii fill-circle isqrt
  attach-screen event-kind fill-rect free-pool gfx-ctrl gfx-on gfx-vbirq
  inp-ctrl
  set-colour rgb
  input-event
  input-pending int-ack int-disable int-enable int-pending int-raise millis
  mouse-x mouse-y op-copy open-screen peek peek8 plot poke poke8
  pool-free-bytes pool-tag pool-used random screen-height screen-sync
  screen-width
  timer-never timer-set-in vblank-count
))

(in-package asm)
;; 101 public, out of 147 definitions.
(export '(
  $a0 $a1 $a2 $a3 $a4 $a5 $a6 $a7 $gp $ra $s0 $s1 $s2 $sp $t0 $t1 $t2 $t3 $t4
  $t5 $t6 $tp $zero
  ;; s3..s11 are where a leaf function keeps its locals, and nothing else in
  ;; the machine touches them.
  $s3 $s4 $s5 $s6 $s7 $s8 $s9 $s10 $s11 asm-code-object asm-gensym-label asm-label asm-len
  asm-literal asm-new asm-origin asm-place asm-place-at csr-cycle
  csr-mcause csr-mepc csr-mie csr-mscratch csr-mstatus csr-mtval csr-mtvec
  i-add i-addi i-and i-andi i-beq i-beqz i-bge i-blt i-bltu i-bne i-bnez
  i-call-reg i-car i-cdr i-csrrci i-csrrs i-csrrsi i-csrrw i-div i-ecall
  i-j i-jal i-jr i-lbu i-ldx i-ldxb i-ldxbi i-ldxi i-lhu i-li i-li-fixnum
  i-lw i-mret
  i-mul i-mv i-not i-or i-ori i-rem i-ret i-sb i-seqz i-set-car i-set-cdr
  i-sh i-sll i-slli i-slt i-snez i-sra i-srai i-srl i-srli i-stx i-stxb
  i-stxbi i-stxi
  i-sub i-sw i-sw-abs i-wfi i-xor i-xori literal-offset op-index
  ;; The B extension: ratified RISC-V, taken rather than invented.
  i-andn i-bclr i-bclri i-bext i-bexti i-binv i-binvi i-bset i-bseti
  i-clz i-cpop i-ctz i-czero-eqz i-czero-nez i-max i-maxu i-min i-minu
  i-orcb i-orn i-rev8 i-rol i-ror i-rori i-sextb i-sexth i-sh1add i-sh2add
  i-sh3add i-xnor i-zexth
))

(in-package compiler)
;; 11 public, out of 100 definitions.
(export '(
  *boot-thunks* add-boot-thunk compile-file-forms compile-function
  compile-top register-instance-layout-in! setup-intrinsics trap-arity
  trap-error trap-oom trap-type
))

(in-package sys)
;; 26 public, out of 69 definitions.
(export '(
  *abort-cleanup-fn* *repl-restart* *resume-fn* *return-addr-fn* *stack-top-fn*
  *task-abort-fn*
  bye compile-time-eval eval eval-form expand-macro handle-trap
  int-external int-software int-timer kickstart macro-form? print-backtrace
  rebuild rebuild-end record-initialiser register-macro repl
  resume-kickstart
  start-repl system-name top-level-form trap-reschedule
))

(in-package exec)
;; 19 public, out of 183 definitions.
(export '(
  add-task cause ctx-bytes disable enable exec-init exec-start forbid
  ;; handle-interrupt and switch-tasks are the trap handler's, and the trap
  ;; handler is in sys: exported to one caller, not to applications.
  handle-interrupt switch-tasks
  idle? idle-start input-listen permit preemption-off task-snapshot task?
  this-task
  rem-task reschedule sigb-input sigb-vblank sigf-input sigf-vblank signal
  spawn *vblank-count* vblank-start wait-input wait-vblank
  task-count tasks wait
))

(in-package snap)
;; 2 public, out of 7 definitions.
(export '(
  save-image save-rebuilt
))

(in-package wb)
;; 33 public, out of 88 definitions.
(export '(
  *windows* front-window make-window new-shell title-height wb-back
  window-rastport wb-update damage draw-in present window-bitmap
  window-damage window-rect wb-composite
  wb-button-down wb-drag wb-face wb-repaint wb-shadow wb-text win-data
  win-inner-h win-inner-w win-inner-x win-inner-y win-refresh win-set!
  win-task window-close window-open
  win-get win-h win-w win-x win-y window-push-key workbench win-bm wb-resume
  pt-black pt-white pt-g1 pt-g2 pt-g3 pt-g6 pt-g7 pt-g8 pt-g10 pt-g13
  pt-lav pt-lav-dark pt-lav-light pt-desktop pt-grey pt-band pt-title-h
  pt-hline pt-vline pt-frame pt-raised pt-sunken pt-title-box pt-grow-box
  platinum-palette text-width text-truncate draw-text draw-char
  make-demo-window win-plot win-point win-fill win-row window-footprint
  draw-mono draw-mono-char mono-width mono-advance mono-height
))

(in-package eyes)
;; 13 public, out of 16 definitions.
(export '(
  *eyes-instances* close-eyes eyes eyes? look-at look-x-of look-y-of
  make-eyes rad-of set-look-x-of! set-look-y-of! set-rad-of! window-of
))

;; A prompt starts here.

(in-package user)
