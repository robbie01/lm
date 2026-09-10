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

(in-package asm)

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

;; The assembler's own state.
(defrecord (assembler asi) buf len labels fixups origin literals nlits)

(define (make-assembler)
  (let ((a (asi-alloc)))
    (set-asi-buf! a (make-bytes-n 512))
    (set-asi-len! a 0)
    (set-asi-origin! a 0)
    (set-asi-nlits! a 0)
    a))

(define (asm-buf a) (asi-buf a))
(define (asm-set-buf! a v) (set-asi-buf! a v))
(define (asm-len a) (asi-len a))
(define (asm-set-len! a v) (set-asi-len! a v))
(define (asm-labels a) (asi-labels a))
(define (asm-set-labels! a v) (set-asi-labels! a v))
(define (asm-fixups a) (asi-fixups a))
(define (asm-set-fixups! a v) (set-asi-fixups! a v))
(define (asm-origin a) (asi-origin a))
(define (asm-set-origin! a v) (set-asi-origin! a v))
(define (asm-literals a) (asi-literals a))
(define (asm-set-literals! a v) (set-asi-literals! a v))
(define (asm-nlits a) (asi-nlits a))
(define (asm-set-nlits! a v) (set-asi-nlits! a v))

(define (asm-literal a obj)
  ;; Record a heap object the code refers to, and answer the slot it will
  ;; occupy in the code object. Code does not contain addresses any more, it
  ;; contains offsets into this vector, which is what lets the collector move
  ;; the object without touching a single instruction.
  ;;
  ;; Repeats share a slot. A function that mentions the same symbol ten times
  ;; gets one word and one load offset, not ten.
  (let ((lits (asm-literals a))
        (n (asm-nlits a))
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
          (asm-set-literals! a (%cons obj lits))
          (asm-set-nlits! a (%+ n 1))
          n))))

;; Byte offset of literal `i` from the code object pointer, which is what the
;; s1 register holds while a compiled function is running.
(define (literal-offset i) (%* 4 (%+ code-lits i)))

(define (literal-count a) (asm-nlits a))

(define (asm-grow a need)
  (let ((buf (asm-buf a)))
    (if (%> need (%bytes-length buf))
        (let ((n (%bytes-length buf)))
          (while (%< n need) (set! n (%* n 2)))
          (let ((nb (make-bytes-n n)) (i 0) (len (asm-len a)))
            (while (%< i len)
              (%bytes-set! nb i (%bytes-ref buf i))
              (set! i (%+ i 1)))
            (asm-set-buf! a nb)))
        nil)))

(define (asm-byte a b)
  (let ((len (asm-len a)))
    (asm-grow a (%+ len 1))
    (%bytes-set! (asm-buf a) len (%logand b 255))
    (asm-set-len! a (%+ len 1))))

(define (asm-half a h)
  (asm-byte a (%logand h 255))
  (asm-byte a (%logand (%lsh h -8) 255)))

;; Emit one 32-bit instruction, low half first.
(define (asm-word a lo hi)
  (asm-half a lo)
  (asm-half a hi))

;; Overwrite an already-emitted instruction, for fixups.
(define (asm-patch a off lo hi)
  (let ((buf (asm-buf a)))
    (%bytes-set! buf off (%logand lo 255))
    (%bytes-set! buf (%+ off 1) (%logand (%lsh lo -8) 255))
    (%bytes-set! buf (%+ off 2) (%logand hi 255))
    (%bytes-set! buf (%+ off 3) (%logand (%lsh hi -8) 255))))

;; ---------------------------------------------------------------- labels
(define (asm-label a name)
  (asm-set-labels! a (%cons (%cons name (asm-len a)) (asm-labels a)))
  name)

(define (asm-label-offset a name)
  (let ((p (assq name (asm-labels a))))
    (if p (%cdr p) (error "assembler: undefined label" name))))

(define (asm-fixup a kind . rest)
  (asm-set-fixups! a (%cons (%cons kind (%cons (asm-len a) rest))
                           (asm-fixups a))))

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
;; custom-0. The processor checks the tag as it forms the address, so a slot
;; access that is handed something else traps instead of loading rubbish.
(define op-pair  #x0b)
;; custom-1: indexed access. funct7 carries the type the object has to be, so
;; one instruction checks the tag, the type, the index and the bound.
(define op-index #x2b)

(define (i-lui a rd imm20)   (i-u a rd imm20 op-lui))
(define (i-auipc a rd imm20) (i-u a rd imm20 op-auipc))

(define (i-addi a rd rs1 imm)
  (cond
   ((if (%= rs1 $zero) (if (%> rd 0) (c-imm6? imm) nil) nil) (i-c-li a rd imm))
   ((if (%= imm 0) (if (%> rd 0) (%> rs1 0) nil) nil) (i-c-mv a rd rs1))
   ((if (%= rd rs1) (if (%> rd 0) (if (%= imm 0) nil (c-imm6? imm)) nil) nil)
    (i-c-addi a rd imm))
   (else (i-i a rd rs1 imm 0 op-imm))))
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
;; ---------------------------------------------------------------- compressed
;; The core has decoded sixteen-bit instructions since the day it was written
;; and nothing ever emitted one. Forty-four per cent of the image turns out to
;; fit, so the emitters below reach for a short form when there is one.
;;
;; Only forms whose encoding does not depend on a distance are compressed. That
;; is what makes this safe with no relaxation pass: shortening an instruction
;; can only shorten the branches around it, and branch offsets are patched from
;; recorded positions after the layout is final. Jumps and branches with an
;; immediate target are therefore left alone.
;;
;; The other rule is that anything re-emitted later at a recorded offset - the
;; two halves of `la`, and the one instruction in the prologue that says how big
;; the frame is - must keep its width. Those use the `-w` emitters below.
(define (c-imm6? v) (if (%>= v -32) (%< v 32) nil))
(define (c-reg? r) (if (%>= r 8) (%<= r 15) nil))
(define (c-word-off? o hi)
  (if (%>= o 0) (if (%< o hi) (%= 0 (%logand o 3)) nil) nil))

(define (c-ci a base rd v)
  (asm-half a (%logior base
                       (%logior (%lsh (%logand rd 31) 7)
                                (%logior (%lsh (%logand v 31) 2)
                                         (%lsh (%logand v 32) 7))))))

(define (i-c-addi a rd v) (c-ci a #x0001 rd v))
(define (i-c-li a rd v)   (c-ci a #x4001 rd v))
(define (i-c-mv a rd rs)
  (asm-half a (%logior #x8002 (%logior (%lsh rd 7) (%lsh rs 2)))))
(define (i-c-jr a rs)   (asm-half a (%logior #x8002 (%lsh rs 7))))
(define (i-c-jalr a rs) (asm-half a (%logior #x9002 (%lsh rs 7))))
(define (i-c-lwsp a rd off)
  (asm-half a (%logior #x4002
                       (%logior (%lsh rd 7)
                                (%logior (%lsh (%logand off #x1c) 2)
                                         (%logior (%lsh (%logand off #x20) 7)
                                                  (%lsh (%logand off #xc0) -4)))))))
(define (i-c-swsp a rs off)
  (asm-half a (%logior #xc002
                       (%logior (%lsh rs 2)
                                (%logior (%lsh (%logand off #x3c) 7)
                                         (%lsh (%logand off #xc0) 1))))))
(define (c-mem a base rd rs1 off)
  (asm-half a (%logior base
                       (%logior (%lsh (%- rd 8) 2)
                                (%logior (%lsh (%- rs1 8) 7)
                                         (%logior (%lsh (%logand off #x38) 7)
                                                  (%logior (%lsh (%logand off 4) 4)
                                                           (%lsh (%logand off #x40) -1))))))))
(define (i-c-lw a rd rs1 off) (c-mem a #x4000 rd rs1 off))
(define (i-c-sw a rs2 rs1 off) (c-mem a #xc000 rs2 rs1 off))

;; ---- the wide forms, for the two places that patch themselves ----
(define (i-addi-w a rd rs1 imm) (i-i a rd rs1 imm 0 op-imm))

(define (i-lw a rd rs1 off)
  (cond
   ((if (%= rs1 $sp) (if (%> rd 0) (c-word-off? off 256) nil) nil)
    (i-c-lwsp a rd off))
   ((if (c-reg? rd) (if (c-reg? rs1) (c-word-off? off 128) nil) nil)
    (i-c-lw a rd rs1 off))
   (else (i-i a rd rs1 off 2 op-load))))
(define (i-lbu a rd rs1 off) (i-i a rd rs1 off 4 op-load))
(define (i-lhu a rd rs1 off) (i-i a rd rs1 off 5 op-load))
(define (i-sb a rs2 rs1 off) (i-s a rs1 rs2 off 0 op-store))
(define (i-sh a rs2 rs1 off) (i-s a rs1 rs2 off 1 op-store))
(define (i-sw a rs2 rs1 off)
  (cond
   ((if (%= rs1 $sp) (c-word-off? off 256) nil) (i-c-swsp a rs2 off))
   ((if (c-reg? rs2) (if (c-reg? rs1) (c-word-off? off 128) nil) nil)
    (i-c-sw a rs2 rs1 off))
   (else (i-s a rs1 rs2 off 2 op-store))))

(define (i-jalr a rd rs1 off)
  (cond
   ((if (%= off 0) (if (%> rs1 0) (%= rd 0) nil) nil) (i-c-jr a rs1))
   ((if (%= off 0) (if (%> rs1 0) (%= rd $ra) nil) nil) (i-c-jalr a rs1))
   (else (i-i a rd rs1 off 0 op-jalr))))

;; custom-0 is RV32I's load and store with the width field spent on the check.
;; Always a word; funct3 says what the base register has to be; the offset says
;; which slot. car and cdr are offsets 0 and 4 of the same instruction.
(define (i-lref a rd rs1 off)  (i-i a rd rs1 off 0 op-pair))
(define (i-lobj a rd rs1 off)  (i-i a rd rs1 off 1 op-pair))
(define (i-sref a rs2 rs1 off) (i-s a rs1 rs2 off 4 op-pair))
(define (i-sobj a rs2 rs1 off) (i-s a rs1 rs2 off 5 op-pair))

(define (i-car a rd rs1)      (i-lref a rd rs1 0))
(define (i-cdr a rd rs1)      (i-lref a rd rs1 4))
(define (i-set-car a rs2 rs1) (i-sref a rs2 rs1 0))
(define (i-set-cdr a rs2 rs1) (i-sref a rs2 rs1 4))

;; rd, object, index - and for the stores rd is the value being written.
(define (i-ldx a rd obj idx ty)  (i-r a ty rd obj idx 0 op-index))
(define (i-stx a val obj idx ty) (i-r a ty val obj idx 1 op-index))
(define (i-ldxb a rd obj idx ty)  (i-r a ty rd obj idx 2 op-index))
(define (i-stxb a val obj idx ty) (i-r a ty val obj idx 3 op-index))
;; The same four with a constant index, which is what a record field, a
;; closure slot and an instance tag always are. The index goes in the rs2
;; field, as an untagged 0..31, the way slli has always kept its shift there.
(define (i-ldxi a rd obj i ty)  (i-r a ty rd obj i 4 op-index))
(define (i-stxi a val obj i ty) (i-r a ty val obj i 5 op-index))
(define (i-ldxbi a rd obj i ty)  (i-r a ty rd obj i 6 op-index))
(define (i-stxbi a val obj i ty) (i-r a ty val obj i 7 op-index))

;; custom-2: fixnum arithmetic. Both operands are checked, which is the check
;; the machine never had - (+ "abc" 2) used to make a cons out of a string.
(define op-fixnum #x5b)
;; custom-3: a fixnum against a constant, and memory through a tagged address.
(define op-tagged #x7b)

(define (i-fadd a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 0 op-fixnum))
(define (i-fsub a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 1 op-fixnum))
(define (i-fmul a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 2 op-fixnum))
(define (i-fdiv a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 3 op-fixnum))
(define (i-frem a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 4 op-fixnum))
(define (i-fand a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 5 op-fixnum))
(define (i-for a rd rs1 rs2)  (i-r a #x00 rd rs1 rs2 6 op-fixnum))
(define (i-fxor a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 7 op-fixnum))
;; The same three, trapping on a result that will not fit in thirty-one bits.
;; Nothing emits them yet: string-hash multiplies past 2^30 on purpose, and
;; what should happen there is a question about bignums, not about encoding.
(define (i-faddo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 0 op-fixnum))
(define (i-fsubo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 1 op-fixnum))
(define (i-fmulo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 2 op-fixnum))
(define (i-fsll a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 0 op-fixnum))
(define (i-fsrl a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 1 op-fixnum))
(define (i-fsra a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 2 op-fixnum))
(define (i-flt a rd rs1 rs2)   (i-r a #x01 rd rs1 rs2 3 op-fixnum))
(define (i-fltu a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 4 op-fixnum))
(define (i-feq a rd rs1 rs2)   (i-r a #x01 rd rs1 rs2 5 op-fixnum))

(define (i-faddi a rd rs1 imm) (i-i a rd rs1 imm 0 op-tagged))
(define (i-fandi a rd rs1 imm) (i-i a rd rs1 imm 1 op-tagged))
(define (i-fori a rd rs1 imm)  (i-i a rd rs1 imm 2 op-tagged))
;; kind 0 left, 1 right logical, 2 right arithmetic.
(define (i-fshi a rd rs1 kind sh)
  (i-i a rd rs1 (%logior (%lsh kind 5) sh) 3 op-tagged))
(define (i-tlw a rd rs1 off) (i-i a rd rs1 off 4 op-tagged))
(define (i-tlb a rd rs1 off) (i-i a rd rs1 off 5 op-tagged))
(define (i-tsw a rs2 rs1 off) (i-s a rs1 rs2 off 6 op-tagged))
(define (i-tsb a rs2 rs1 off) (i-s a rs1 rs2 off 7 op-tagged))

;; ---- B extension: Zba, Zbb, Zbs; and Zicond ----
;; Ratified RISC-V rather than ours. Taking these first is what stops the
;; custom opcodes growing to cover ground the committee already covered.
(define (i-sh1add a rd rs1 rs2) (i-r a #x10 rd rs1 rs2 2 op-reg))
(define (i-sh2add a rd rs1 rs2) (i-r a #x10 rd rs1 rs2 4 op-reg))
(define (i-sh3add a rd rs1 rs2) (i-r a #x10 rd rs1 rs2 6 op-reg))
(define (i-andn a rd rs1 rs2)   (i-r a #x20 rd rs1 rs2 7 op-reg))
(define (i-orn a rd rs1 rs2)    (i-r a #x20 rd rs1 rs2 6 op-reg))
(define (i-xnor a rd rs1 rs2)   (i-r a #x20 rd rs1 rs2 4 op-reg))
(define (i-min a rd rs1 rs2)    (i-r a #x05 rd rs1 rs2 4 op-reg))
(define (i-minu a rd rs1 rs2)   (i-r a #x05 rd rs1 rs2 5 op-reg))
(define (i-max a rd rs1 rs2)    (i-r a #x05 rd rs1 rs2 6 op-reg))
(define (i-maxu a rd rs1 rs2)   (i-r a #x05 rd rs1 rs2 7 op-reg))
(define (i-rol a rd rs1 rs2)    (i-r a #x30 rd rs1 rs2 1 op-reg))
(define (i-ror a rd rs1 rs2)    (i-r a #x30 rd rs1 rs2 5 op-reg))
(define (i-rori a rd rs1 sh)    (i-r a #x30 rd rs1 sh 5 op-imm))
(define (i-bset a rd rs1 rs2)   (i-r a #x14 rd rs1 rs2 1 op-reg))
(define (i-bclr a rd rs1 rs2)   (i-r a #x24 rd rs1 rs2 1 op-reg))
(define (i-binv a rd rs1 rs2)   (i-r a #x34 rd rs1 rs2 1 op-reg))
(define (i-bext a rd rs1 rs2)   (i-r a #x24 rd rs1 rs2 5 op-reg))
(define (i-bseti a rd rs1 sh)   (i-r a #x14 rd rs1 sh 1 op-imm))
(define (i-bclri a rd rs1 sh)   (i-r a #x24 rd rs1 sh 1 op-imm))
(define (i-binvi a rd rs1 sh)   (i-r a #x34 rd rs1 sh 1 op-imm))
(define (i-bexti a rd rs1 sh)   (i-r a #x24 rd rs1 sh 5 op-imm))
(define (i-clz a rd rs1)        (i-r a #x30 rd rs1 0 1 op-imm))
(define (i-ctz a rd rs1)        (i-r a #x30 rd rs1 1 1 op-imm))
(define (i-cpop a rd rs1)       (i-r a #x30 rd rs1 2 1 op-imm))
(define (i-sextb a rd rs1)      (i-r a #x30 rd rs1 4 1 op-imm))
(define (i-sexth a rd rs1)      (i-r a #x30 rd rs1 5 1 op-imm))
(define (i-zexth a rd rs1)      (i-r a #x04 rd rs1 0 4 op-reg))
(define (i-rev8 a rd rs1)       (i-r a #x34 rd rs1 #x18 5 op-imm))
(define (i-orcb a rd rs1)       (i-r a #x14 rd rs1 7 5 op-imm))
;; rd <- (rs2 = 0) ? 0 : rs1, and its opposite. A branchless select on a
;; machine with no flags register.
(define (i-czero-eqz a rd rs1 rs2) (i-r a #x07 rd rs1 rs2 5 op-reg))
(define (i-czero-nez a rd rs1 rs2) (i-r a #x07 rd rs1 rs2 7 op-reg))
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
  ;; Both halves stay wide: `asm-resolve` rewinds to this offset and writes
  ;; them again, and it has to write the same number of bytes.
  (asm-fixup a 'la rd label)
  (i-auipc a rd 0)
  (i-addi-w a rd rd 0))

;; ---------------------------------------------------------------- resolution
(define (asm-resolve a)
  (let ((fixups (reverse (asm-fixups a))))
    (dolist (f fixups)
      (let* ((kind (%car f))
             (off (cadr f))
             (rest (cddr f)))
        (cond
         ((%eq? kind 'b)
          (let* ((f3 (%car rest)) (rs1 (cadr rest)) (rs2 (caddr rest))
                 (label (cadddr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (save (asm-len a)))
            (if (if (%>= delta -4096) (%< delta 4096) nil)
                nil
                (error "assembler: branch out of range" label delta))
            ;; Re-encode in place by pointing the emitter at the patch site.
            (asm-set-len! a off)
            (i-b a rs1 rs2 delta f3 op-br)
            (asm-set-len! a save)))
         ((%eq? kind 'jal)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (save (asm-len a)))
            (if (if (%>= delta -1048576) (%< delta 1048576) nil)
                nil
                (error "assembler: jump out of range" label delta))
            (asm-set-len! a off)
            (enc-j a rd delta op-jal)
            (asm-set-len! a save)))
         ((%eq? kind 'la)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (asm-label-offset a label) off))
                 (lo (%logand delta #xfff))
                 (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
                 (hi (%logand (%lsh (%- delta lo-signed) -12) #xfffff))
                 (save (asm-len a)))
            (asm-set-len! a off)
            (i-auipc a rd hi)
            (i-addi-w a rd rd lo-signed)
            (asm-set-len! a save)))
         (else (error "assembler: unknown fixup" kind)))))
    (asm-set-fixups! a nil)
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
  (asm-set-origin! a addr)
  (asm-resolve a)
  (let ((len (asm-len a))
        (buf (asm-buf a))
        (i 0))
    (while (%< i len)
      (%st-byte! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1)))
    addr))

(define (asm-place a)
  (asm-resolve a)
  (let* ((len (asm-len a))
         (addr (alloc-code len))
         (buf (asm-buf a))
         (i 0))
    (while (%< i len)
      (%st-byte! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1)))
    (asm-set-origin! a addr)
    addr))

;; Turn the assembler's output into a heap object, so the collector can see
;; both the machine code and every literal the code refers to.
(define (asm-code-object a name)
  ;; The literals list is in reverse, so it fills the vector from the far end.
  (let* ((n (asm-nlits a))
         (v (alloc-object t-code (%+ code-lits n)))
         (i (%- (%+ code-lits n) 1)))
    (%st-fixnum! (%addr-of v) (asm-origin a))          ; raw entry address
    (%st-fixnum! (%+ (%addr-of v) 4) (asm-len a))   ; raw byte length
    ;; Who this is. Every frame has its code object in s1 and saves its
    ;; caller's, so this one word is what turns the frame chain into a
    ;; backtrace.
    (%set-slot! v code-name name)
    (dolist (l (asm-literals a))
      (%set-slot! v i l)
      (set! i (%- i 1)))
    ;; The collector finds code through this, not by scanning code space,
    ;; which has no headers to walk.
    (register-code v)
    v))

(define (code-object-entry v) (%addr-of (%ld-word (%addr-of v))))
