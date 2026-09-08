;;; asm.lisp - an RV32IM assembler, in Lisp.
;;;
;;; This is the real assembler: the same code runs under the bootstrap
;;; interpreter while the image is being built, and again as compiled native
;;; code inside the running machine, which is what lets the image compile new
;;; Lisp for itself.
;;;
;;; Instructions are assembled a halfword at a time. That is not an aesthetic
;;; choice: a fixnum holds 31 bits, so a whole 32-bit instruction word does not
;;; fit in one, and every encoder here builds a low half and a high half. Only
;;; rs1 straddles the boundary, at bit 15.

;; ---------------------------------------------------------------- registers
(define $zero 0) (define $ra 1)  (define $sp 2)  (define $gp 3)
(define $tp 4)   (define $t0 5)  (define $t1 6)  (define $t2 7)
(define $s0 8)   (define $s1 9)  (define $a0 10) (define $a1 11)
(define $a2 12)  (define $a3 13) (define $a4 14) (define $a5 15)
(define $a6 16)  (define $a7 17) (define $s2 18) (define $s3 19)
(define $s4 20)  (define $s5 21) (define $s6 22) (define $s7 23)
(define $s8 24)  (define $s9 25) (define $s10 26) (define $s11 27)
(define $t3 28)  (define $t4 29) (define $t5 30) (define $t6 31)

;; gp is the cons bump pointer and tp is its limit; see the comment on
;; `i-cons` below. Nothing else may use them.
(define $consp $gp)
(define $consend $tp)

;; ---------------------------------------------------------------- csr numbers
(define csr-mstatus  #x300)
(define csr-mie      #x304)
(define csr-mtvec    #x305)
(define csr-mscratch #x340)
(define csr-mepc     #x341)
(define csr-mcause   #x342)
(define csr-mtval    #x343)
(define csr-mip      #x344)
(define csr-cycle    #xc00)
(define csr-cycleh   #xc80)

;; ---------------------------------------------------------------- the buffer
;; An assembler is a 6-slot vector:
;;   0 bytes    the growable output buffer
;;   1 len      bytes used
;;   2 labels   alist of (name . byte-offset)
;;   3 fixups   reversed list of pending relocations
;;   4 origin   address the code will live at, once known
;;   5 literals objects the code refers to, kept alive by the code object

(define (asm-new)
  (let ((a (make-vector-n 7 nil)))
    (%vector-set! a 0 (make-bytes-n 512))
    (%vector-set! a 1 0)
    (%vector-set! a 2 nil)
    (%vector-set! a 3 nil)
    (%vector-set! a 4 0)
    (%vector-set! a 5 nil)
    (%vector-set! a 6 0)
    a))

(define (asm-len a) (%vector-ref a 1))
(define (asm-origin a) (%vector-ref a 4))
(define (asm-literals a) (%vector-ref a 5))

(define (asm-literal a obj)
  ;; Record a heap object the code refers to, and answer the slot it will
  ;; occupy in the code object. Code does not contain addresses any more, it
  ;; contains offsets into this vector, which is what lets the collector move
  ;; the object without touching a single instruction.
  ;;
  ;; Repeats share a slot. A function that mentions the same symbol ten times
  ;; gets one word and one load offset, not ten.
  (let ((lits (%vector-ref a 5))
        (n (%vector-ref a 6))
        (found nil)
        (k 0)
        (p nil))
    (set! p lits)
    (while (if found nil (%cons? p))
      (if (%eq? (%car p) obj) (set! found (%- (%- n 1) k)) nil)
      (set! k (%+ k 1))
      (set! p (%cdr p)))
    (if found
        found
        (begin
          (%vector-set! a 5 (%cons obj lits))
          (%vector-set! a 6 (%+ n 1))
          n))))

;; Byte offset of literal `i` from the code object pointer, which is what the
;; s1 register holds while a compiled function is running.
(define (literal-offset i) (%* 4 (%+ code-lits i)))

(define (literal-count a) (%vector-ref a 6))

(define (asm-grow a need)
  (let ((buf (%vector-ref a 0)))
    (if (%> need (%bytes-length buf))
        (let ((n (%bytes-length buf)))
          (while (%< n need) (set! n (%* n 2)))
          (let ((nb (make-bytes-n n)) (i 0) (len (%vector-ref a 1)))
            (while (%< i len)
              (%bytes-set! nb i (%bytes-ref buf i))
              (set! i (%+ i 1)))
            (%vector-set! a 0 nb)))
        nil)))

(define (asm-byte a b)
  (let ((len (%vector-ref a 1)))
    (asm-grow a (%+ len 1))
    (%bytes-set! (%vector-ref a 0) len (%logand b 255))
    (%vector-set! a 1 (%+ len 1))))

(define (asm-half a h)
  (asm-byte a (%logand h 255))
  (asm-byte a (%logand (%lsh h -8) 255)))

;; Emit one 32-bit instruction, low half first.
(define (asm-word a lo hi)
  (asm-half a lo)
  (asm-half a hi))

;; Overwrite an already-emitted instruction, for fixups.
(define (asm-patch a off lo hi)
  (let ((buf (%vector-ref a 0)))
    (%bytes-set! buf off (%logand lo 255))
    (%bytes-set! buf (%+ off 1) (%logand (%lsh lo -8) 255))
    (%bytes-set! buf (%+ off 2) (%logand hi 255))
    (%bytes-set! buf (%+ off 3) (%logand (%lsh hi -8) 255))))

;; ---------------------------------------------------------------- labels
(define (asm-label a name)
  (%vector-set! a 2 (%cons (%cons name (%vector-ref a 1)) (%vector-ref a 2)))
  name)

(define (asm-label-offset a name)
  (let ((p (assq name (%vector-ref a 2))))
    (if p (%cdr p) (error "assembler: undefined label" name))))

(define (asm-fixup a kind . rest)
  (%vector-set! a 3 (%cons (%cons kind (%cons (%vector-ref a 1) rest))
                           (%vector-ref a 3))))

(define gensym-counter 0)
(define (asm-gensym-label prefix)
  (set! gensym-counter (%+ gensym-counter 1))
  (intern-string (string-append prefix (number->string gensym-counter))))

;; ---------------------------------------------------------------- encoders
;; Field positions in a 32-bit instruction, and which half each lands in:
;;   opcode  0..6    low          rs1     15..19  bit 15 low, 16..19 high
;;   rd      7..11   low          rs2     20..24  high
;;   funct3  12..14  low          funct7  25..31  high
(define (enc-lo rs1 f3 rd op)
  (%logior (%lsh (%logand rs1 1) 15)
           (%logior (%lsh (%logand f3 7) 12)
                    (%logior (%lsh (%logand rd 31) 7) (%logand op 127)))))

(define (enc-hi f7 rs2 rs1)
  (%logior (%lsh (%logand f7 127) 9)
           (%logior (%lsh (%logand rs2 31) 4) (%lsh (%logand rs1 31) -1))))

(define (i-r a f7 rd rs1 rs2 f3 op)
  (asm-word a (enc-lo rs1 f3 rd op) (enc-hi f7 rs2 rs1)))

(define (i-i a rd rs1 imm f3 op)
  ;; imm[11:0] occupies bits 20..31, that is high bits 4..15.
  (asm-word a
            (enc-lo rs1 f3 rd op)
            (%logior (%lsh (%logand imm #xfff) 4) (%lsh (%logand rs1 31) -1))))

(define (i-s a rs1 rs2 imm f3 op)
  ;; imm[4:0] -> bits 7..11, imm[11:5] -> bits 25..31 (high 9..15)
  (asm-word a
            (enc-lo rs1 f3 (%logand imm 31) op)
            (%logior (%lsh (%logand (%lsh imm -5) 127) 9)
                     (%logior (%lsh (%logand rs2 31) 4) (%lsh (%logand rs1 31) -1)))))

(define (i-b a rs1 rs2 imm f3 op)
  ;; imm[11]->bit7, imm[4:1]->bits 8..11, imm[10:5]->bits 25..30, imm[12]->bit31
  (let ((rd-field (%logior (%logand (%lsh imm -11) 1)
                           (%lsh (%logand (%lsh imm -1) 15) 1)))
        (f7-field (%logior (%logand (%lsh imm -5) 63)
                           (%lsh (%logand (%lsh imm -12) 1) 6))))
    (asm-word a
              (enc-lo rs1 f3 rd-field op)
              (%logior (%lsh f7-field 9)
                       (%logior (%lsh (%logand rs2 31) 4) (%lsh (%logand rs1 31) -1))))))

(define (i-u a rd imm20 op)
  ;; imm20 occupies bits 12..31: low half takes its bits 0..3.
  (asm-word a
            (%logior (%lsh (%logand imm20 15) 12)
                     (%logior (%lsh (%logand rd 31) 7) op))
            (%logand (%lsh imm20 -4) #xffff)))

(define (enc-j a rd imm op)
  ;; imm[19:12]->bits 12..19, imm[11]->bit 20, imm[10:1]->bits 21..30,
  ;; imm[20]->bit 31. Written as a U-type field for convenience.
  (let ((f (%logior (%logand (%lsh imm -12) 255)
                    (%logior (%lsh (%logand (%lsh imm -11) 1) 8)
                             (%logior (%lsh (%logand (%lsh imm -1) 1023) 9)
                                      (%lsh (%logand (%lsh imm -20) 1) 19))))))
    (i-u a rd f op)))

;; ---------------------------------------------------------------- RV32I
(define op-load  #x03)
(define op-imm   #x13)
(define op-auipc #x17)
(define op-store #x23)
(define op-reg   #x33)
(define op-lui   #x37)
(define op-br    #x63)
(define op-jalr  #x67)
(define op-jal   #x6f)
(define op-sys   #x73)
;; custom-0. The processor checks the tag as it forms the address, so a pair
;; access that is handed something else traps instead of loading rubbish.
(define op-pair  #x0b)

(define (i-lui a rd imm20)   (i-u a rd imm20 op-lui))
(define (i-auipc a rd imm20) (i-u a rd imm20 op-auipc))

(define (i-addi a rd rs1 imm) (i-i a rd rs1 imm 0 op-imm))
(define (i-slti a rd rs1 imm) (i-i a rd rs1 imm 2 op-imm))
(define (i-sltiu a rd rs1 imm) (i-i a rd rs1 imm 3 op-imm))
(define (i-xori a rd rs1 imm) (i-i a rd rs1 imm 4 op-imm))
(define (i-ori a rd rs1 imm)  (i-i a rd rs1 imm 6 op-imm))
(define (i-andi a rd rs1 imm) (i-i a rd rs1 imm 7 op-imm))
(define (i-slli a rd rs1 sh)  (i-r a 0 rd rs1 sh 1 op-imm))
(define (i-srli a rd rs1 sh)  (i-r a 0 rd rs1 sh 5 op-imm))
(define (i-srai a rd rs1 sh)  (i-r a #x20 rd rs1 sh 5 op-imm))

(define (i-add a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 0 op-reg))
(define (i-sub a rd rs1 rs2)  (i-r a #x20 rd rs1 rs2 0 op-reg))
(define (i-sll a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 1 op-reg))
(define (i-slt a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 2 op-reg))
(define (i-sltu a rd rs1 rs2) (i-r a 0 rd rs1 rs2 3 op-reg))
(define (i-xor a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 4 op-reg))
(define (i-srl a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 5 op-reg))
(define (i-sra a rd rs1 rs2)  (i-r a #x20 rd rs1 rs2 5 op-reg))
(define (i-or a rd rs1 rs2)   (i-r a 0 rd rs1 rs2 6 op-reg))
(define (i-and a rd rs1 rs2)  (i-r a 0 rd rs1 rs2 7 op-reg))

(define (i-mul a rd rs1 rs2)    (i-r a 1 rd rs1 rs2 0 op-reg))
(define (i-mulh a rd rs1 rs2)   (i-r a 1 rd rs1 rs2 1 op-reg))
(define (i-mulhsu a rd rs1 rs2) (i-r a 1 rd rs1 rs2 2 op-reg))
(define (i-mulhu a rd rs1 rs2)  (i-r a 1 rd rs1 rs2 3 op-reg))
(define (i-div a rd rs1 rs2)    (i-r a 1 rd rs1 rs2 4 op-reg))
(define (i-divu a rd rs1 rs2)   (i-r a 1 rd rs1 rs2 5 op-reg))
(define (i-rem a rd rs1 rs2)    (i-r a 1 rd rs1 rs2 6 op-reg))
(define (i-remu a rd rs1 rs2)   (i-r a 1 rd rs1 rs2 7 op-reg))

(define (i-lb a rd rs1 off)  (i-i a rd rs1 off 0 op-load))
(define (i-lh a rd rs1 off)  (i-i a rd rs1 off 1 op-load))
(define (i-lw a rd rs1 off)  (i-i a rd rs1 off 2 op-load))
(define (i-lbu a rd rs1 off) (i-i a rd rs1 off 4 op-load))
(define (i-lhu a rd rs1 off) (i-i a rd rs1 off 5 op-load))
(define (i-sb a rs2 rs1 off) (i-s a rs1 rs2 off 0 op-store))
(define (i-sh a rs2 rs1 off) (i-s a rs1 rs2 off 1 op-store))
(define (i-sw a rs2 rs1 off) (i-s a rs1 rs2 off 2 op-store))

(define (i-jalr a rd rs1 off) (i-i a rd rs1 off 0 op-jalr))

(define (i-car a rd rs1)      (i-i a rd rs1 0 0 op-pair))
(define (i-cdr a rd rs1)      (i-i a rd rs1 0 1 op-pair))
(define (i-set-car a rs2 rs1) (i-s a rs1 rs2 0 2 op-pair))
(define (i-set-cdr a rs2 rs1) (i-s a rs1 rs2 0 3 op-pair))
(define (i-ret a) (i-jalr a $zero $ra 0))
(define (i-jr a rs) (i-jalr a $zero rs 0))
(define (i-call-reg a rs) (i-jalr a $ra rs 0))

(define (i-ecall a)  (i-i a 0 0 0 0 op-sys))
(define (i-ebreak a) (i-i a 0 0 1 0 op-sys))
(define (i-mret a)   (i-i a 0 0 #x302 0 op-sys))
(define (i-wfi a)    (i-i a 0 0 #x105 0 op-sys))
(define (i-csrrw a rd csr rs1) (i-i a rd rs1 csr 1 op-sys))
(define (i-csrrs a rd csr rs1) (i-i a rd rs1 csr 2 op-sys))
(define (i-csrrc a rd csr rs1) (i-i a rd rs1 csr 3 op-sys))
(define (i-csrrwi a rd csr im) (i-i a rd im csr 5 op-sys))
(define (i-csrrsi a rd csr im) (i-i a rd im csr 6 op-sys))
(define (i-csrrci a rd csr im) (i-i a rd im csr 7 op-sys))

;; ---------------------------------------------------------------- pseudo-ops
(define (i-nop a) (i-addi a $zero $zero 0))
(define (i-mv a rd rs) (i-addi a rd rs 0))
(define (i-neg a rd rs) (i-sub a rd $zero rs))
(define (i-not a rd rs) (i-xori a rd rs -1))
(define (i-seqz a rd rs) (i-sltiu a rd rs 1))
(define (i-snez a rd rs) (i-sltu a rd $zero rs))

(define (fits12? n) (if (%>= n -2048) (%< n 2048) nil))

;; Load a 32-bit constant. Addresses are signed throughout, so a value with the
;; top bit set arrives here as a negative number and encodes identically.
(define (i-li a rd v)
  (if (fits12? v)
      (i-addi a rd $zero v)
      (let* ((lo (%logand v #xfff))
             (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
             (hi (%logand (%lsh (%- v lo-signed) -12) #xfffff)))
        (i-lui a rd hi)
        (if (%= lo-signed 0) nil (i-addi a rd rd lo-signed)))))


;; Materialise the tagged form of a fixnum, that is 2v+1.
;;
;; This cannot go through i-li, because 2v+1 does not fit in a fixnum once
;; |v| reaches 2^29 - the compiler would be asking the assembler to represent
;; the very value it cannot represent. So the lui and addi fields are computed
;; from v directly and 2v+1 is never formed. Getting this wrong is quiet and
;; expensive: a miscompiled mask silently changes a hash, and a hash that
;; disagrees with the one the forge used means every symbol interns twice.
(define (i-li-fixnum a rd v)
  (if (if (%>= v -1024) (%< v 1024) nil)
      (i-addi a rd $zero (%+ (%* 2 v) 1))
      (let* ((lo (%logand (%+ (%* 2 (%logand v 2047)) 1) 4095))
             (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
             ;; 2v+1-lo-signed is 2(v+k), and divisible by 4096, so the high
             ;; field is (v+k)/2048 with nothing overflowing on the way.
             (k (%/ (%- 1 lo-signed) 2))
             (hi (%logand (%/ (%+ v k) 2048) #xfffff)))
        (i-lui a rd hi)
        (if (%= lo-signed 0) nil (i-addi a rd rd lo-signed)))))

;; Load or store at an arbitrary absolute address, via a scratch register.
(define (i-lw-abs a rd addr scratch)
  (if (fits12? addr)
      (i-lw a rd $zero addr)
      (begin (i-li a scratch (%- addr (%logand addr #xfff)))
             (i-lw a rd scratch (sign12 (%logand addr #xfff))))))

(define (i-sw-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sw a rs $zero addr)
      (begin (i-li a scratch (%- addr (%logand addr #xfff)))
             (i-sw a rs scratch (sign12 (%logand addr #xfff))))))

(define (sign12 n) (if (%>= n 2048) (%- n 4096) n))

;; ---------------------------------------------------------------- branches
;; Label-relative forms record a fixup and are patched once every label is
;; placed. Sizes never change, so one pass of patching is enough.

(define (i-branch a f3 rs1 rs2 label)
  (asm-fixup a 'b f3 rs1 rs2 label)
  (i-b a rs1 rs2 0 f3 op-br))

(define (i-beq a rs1 rs2 label)  (i-branch a 0 rs1 rs2 label))
(define (i-bne a rs1 rs2 label)  (i-branch a 1 rs1 rs2 label))
(define (i-blt a rs1 rs2 label)  (i-branch a 4 rs1 rs2 label))
(define (i-bge a rs1 rs2 label)  (i-branch a 5 rs1 rs2 label))
(define (i-bltu a rs1 rs2 label) (i-branch a 6 rs1 rs2 label))
(define (i-bgeu a rs1 rs2 label) (i-branch a 7 rs1 rs2 label))
(define (i-bgt a rs1 rs2 label)  (i-branch a 4 rs2 rs1 label))
(define (i-ble a rs1 rs2 label)  (i-branch a 5 rs2 rs1 label))
(define (i-beqz a rs label)      (i-branch a 0 rs $zero label))
(define (i-bnez a rs label)      (i-branch a 1 rs $zero label))

(define (i-j a label)
  (asm-fixup a 'jal $zero label)
  (enc-j a $zero 0 op-jal))

(define (i-jal a rd label)
  (asm-fixup a 'jal rd label)
  (enc-j a rd 0 op-jal))

;; Address of a label, as auipc + addi. Always two instructions so that
;; offsets stay stable.
(define (i-la a rd label)
  (asm-fixup a 'la rd label)
  (i-auipc a rd 0)
  (i-addi a rd rd 0))

;; ---------------------------------------------------------------- resolution
(define (asm-resolve a)
  (let ((fixups (reverse (%vector-ref a 3))))
    (dolist (f fixups)
      (let* ((kind (%car f))
             (off (cadr f))
             (rest (cddr f)))
        (cond
         ((%eq? kind 'b)
          (let* ((f3 (%car rest)) (rs1 (cadr rest)) (rs2 (caddr rest))
                 (label (cadddr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (save (%vector-ref a 1)))
            (if (if (%>= delta -4096) (%< delta 4096) nil)
                nil
                (error "assembler: branch out of range" label delta))
            ;; Re-encode in place by pointing the emitter at the patch site.
            (%vector-set! a 1 off)
            (i-b a rs1 rs2 delta f3 op-br)
            (%vector-set! a 1 save)))
         ((%eq? kind 'jal)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (save (%vector-ref a 1)))
            (if (if (%>= delta -1048576) (%< delta 1048576) nil)
                nil
                (error "assembler: jump out of range" label delta))
            (%vector-set! a 1 off)
            (enc-j a rd delta op-jal)
            (%vector-set! a 1 save)))
         ((%eq? kind 'la)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (lo (%logand delta #xfff))
                 (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
                 (hi (%logand (%lsh (%- delta lo-signed) -12) #xfffff))
                 (save (%vector-ref a 1)))
            (%vector-set! a 1 off)
            (i-auipc a rd hi)
            (i-addi a rd rd lo-signed)
            (%vector-set! a 1 save)))
         (else (error "assembler: unknown fixup" kind)))))
    (%vector-set! a 3 nil)
    a))

;; ---------------------------------------------------------------- placement
;; Copy the assembled bytes into code space and hand back the entry address.
;; Code space never moves and is never compacted, so the address baked into a
;; closure stays valid for the life of the image.
(define (asm-place-at a addr)
  ;; Write the assembled bytes to an address that was reserved earlier. The
  ;; reset stub needs this: it has to sit at the base of code space, because
  ;; that is where the processor starts, but it cannot be assembled until the
  ;; things it refers to have addresses.
  (%vector-set! a 4 addr)
  (asm-resolve a)
  (let ((len (%vector-ref a 1))
        (buf (%vector-ref a 0))
        (i 0))
    (while (%< i len)
      (%st8! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1)))
    addr))

(define (asm-place a)
  (asm-resolve a)
  (let* ((len (%vector-ref a 1))
         (addr (alloc-code len))
         (buf (%vector-ref a 0))
         (i 0))
    (while (%< i len)
      (%st8! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1)))
    (%vector-set! a 4 addr)
    addr))

;; Turn the assembler's output into a heap object, so the collector can see
;; both the machine code and every literal the code refers to.
(define (asm-code-object a name)
  ;; The literals list is in reverse, so it fills the vector from the far end.
  (let* ((n (%vector-ref a 6))
         (v (alloc-object t-code (%+ code-lits n)))
         (i (%- (%+ code-lits n) 1)))
    (%st32! (%addr-of v) (%vector-ref a 4))          ; raw entry address
    (%st32! (%+ (%addr-of v) 4) (%vector-ref a 1))   ; raw byte length
    ;; Who this is. Every frame has its code object in s1 and saves its
    ;; caller's, so this one word is what turns the frame chain into a
    ;; backtrace.
    (%set-slot! v code-name name)
    (dolist (l (%vector-ref a 5))
      (%set-slot! v i l)
      (set! i (%- i 1)))
    ;; The collector finds code through this, not by scanning code space,
    ;; which has no headers to walk.
    (register-code v)
    v))

(define (code-object-entry v) (%addr-of (%raw-ld (%addr-of v))))
