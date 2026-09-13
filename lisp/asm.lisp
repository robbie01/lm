;;; asm.lisp - an RV32IMC assembler.
;;;
;;; The forge's interpreter runs this while the image is built, and the
;;; compiled copy in the image runs it when the machine compiles for itself.
;;;
;;; Instructions are assembled a halfword at a time: a fixnum holds 31 bits,
;;; so a whole instruction word does not fit in one. Every encoder builds a
;;; low half and a high half. Only rs1 straddles the boundary, at bit 15.

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

;; gp is the cons bump pointer and tp its limit, for the life of the machine.
;; Nothing else may use them.
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
(define csr-stklim   #x7c0)   ; custom: the lowest address sp may reach
(define csr-gcmode   #x7c1)   ; custom: bit 0 turns the write barrier on
(define csr-cycle    #xc00)
(define csr-cycleh   #xc80)

;; ---------------------------------------------------------------- the buffer
;; buf is the output buffer and len the bytes of it used. labels is an alist
;; of (name . byte-offset). fixups is the list of pending relocations, newest
;; first. origin is the address the code was placed at. literals is the list
;; of heap objects the code refers to, newest first, and nlits its length.
(defrecord (assembler asm) buf len labels fixups origin literals nlits)

(define (make-assembler)
  (let ((a (asm-alloc)))
    (set-asm-buf! a (make-bytes-n 512))
    (set-asm-len! a 0)
    (set-asm-origin! a 0)
    (set-asm-nlits! a 0)
    a))

;; Record a heap object the code refers to, and answer its slot in the code
;; object. Code holds no object addresses: it loads an object from the code
;; object's literal vector, so the collector can move the object by updating
;; one word. A repeated object shares a slot.
(define (literal a obj)
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
          (set-asm-literals! a (%cons obj lits))
          (set-asm-nlits! a (%+ n 1))
          n))))

;; Byte offset of literal i from the code object pointer, which s1 holds
;; while a compiled function runs.
(define (literal-offset i) (%* 4 (%+ code-lits i)))

(define (grow a need)
  (let ((buf (asm-buf a)))
    (if (%> need (%bytes-length buf))
        (let ((n (%bytes-length buf)))
          (while (%< n need) (set! n (%* n 2)))
          (let ((nb (make-bytes-n n)) (i 0) (len (asm-len a)))
            (while (%< i len)
              (%bytes-set! nb i (%bytes-ref buf i))
              (set! i (%+ i 1)))
            (set-asm-buf! a nb)))
        nil)))

(define (half a h)
  (let ((len (asm-len a)))
    (grow a (%+ len 2))
    (let ((buf (asm-buf a)))
      (%bytes-set! buf len (%logand h 255))
      (%bytes-set! buf (%+ len 1) (%logand (%lsh h -8) 255)))
    (set-asm-len! a (%+ len 2))))

;; One 32-bit instruction, low half first.
(define (word a lo hi)
  (let ((len (asm-len a)))
    (grow a (%+ len 4))
    (let ((buf (asm-buf a)))
      (%bytes-set! buf len (%logand lo 255))
      (%bytes-set! buf (%+ len 1) (%logand (%lsh lo -8) 255))
      (%bytes-set! buf (%+ len 2) (%logand hi 255))
      (%bytes-set! buf (%+ len 3) (%logand (%lsh hi -8) 255)))
    (set-asm-len! a (%+ len 4))))

;; ---------------------------------------------------------------- labels
(define (label a name)
  (set-asm-labels! a (%cons (%cons name (asm-len a)) (asm-labels a)))
  name)

(define (label-offset a name)
  (let ((p (assq name (asm-labels a))))
    (if p (%cdr p) (error "assembler: undefined label" name))))

(define (fixup a kind . rest)
  (set-asm-fixups! a (%cons (%cons kind (%cons (asm-len a) rest))
                            (asm-fixups a))))

;; A label is found again with `assq` and nothing else, so any object that is
;; eq only to itself will do. A fresh string is garbage once the function is
;; placed, where an interned symbol would stay in the obarray for ever, and
;; it still reads as a name in an "undefined label" message.
(define *label-count* 0)
(define (gensym-label prefix)
  (set! *label-count* (%+ *label-count* 1))
  (string-append prefix (number->string *label-count*)))

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
  (word a (enc-lo rs1 f3 rd op) (enc-hi f7 rs2 rs1)))

;; imm[11:0] occupies bits 20..31, which is high bits 4..15.
(define (i-i a rd rs1 imm f3 op)
  (word a
            (enc-lo rs1 f3 rd op)
            (%logior (%lsh (%logand imm #xfff) 4) (%lsh (%logand rs1 31) -1))))

;; imm[4:0] in bits 7..11, imm[11:5] in bits 25..31 (high 9..15).
(define (i-s a rs1 rs2 imm f3 op)
  (word a
            (enc-lo rs1 f3 (%logand imm 31) op)
            (%logior (%lsh (%logand (%lsh imm -5) 127) 9)
                     (%logior (%lsh (%logand rs2 31) 4) (%lsh (%logand rs1 31) -1)))))

;; imm[11] in bit 7, imm[4:1] in bits 8..11, imm[10:5] in bits 25..30,
;; imm[12] in bit 31.
(define (i-b a rs1 rs2 imm f3 op)
  (let ((rd-field (%logior (%logand (%lsh imm -11) 1)
                           (%lsh (%logand (%lsh imm -1) 15) 1)))
        (f7-field (%logior (%logand (%lsh imm -5) 63)
                           (%lsh (%logand (%lsh imm -12) 1) 6))))
    (word a
              (enc-lo rs1 f3 rd-field op)
              (%logior (%lsh f7-field 9)
                       (%logior (%lsh (%logand rs2 31) 4) (%lsh (%logand rs1 31) -1))))))

;; imm20 occupies bits 12..31: the low half takes its bits 0..3.
(define (i-u a rd imm20 op)
  (word a
            (%logior (%lsh (%logand imm20 15) 12)
                     (%logior (%lsh (%logand rd 31) 7) op))
            (%logand (%lsh imm20 -4) #xffff)))

;; imm[19:12] in bits 12..19, imm[11] in bit 20, imm[10:1] in bits 21..30,
;; imm[20] in bit 31, assembled as a U-type field.
(define (enc-j a rd imm op)
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
;; custom-0: a word load or store that checks the tag of its base register as
;; it forms the address.
(define op-pair  #x0b)
;; custom-1: indexed access. funct7 carries the type the object has to be, so
;; one instruction checks the tag, the type, the index and the bound.
(define op-index #x2b)
;; custom-2: fixnum arithmetic with both operands checked.
(define op-fixnum #x5b)
;; custom-3: a fixnum against a constant, and memory through a tagged address.
(define op-tagged #x7b)

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

;; ---------------------------------------------------------------- compressed
;; The emitters below use a sixteen-bit form when there is one. Only forms
;; whose encoding does not depend on a distance are compressed, so no
;; relaxation pass is needed: shortening an instruction can only shorten the
;; branches around it, and branch offsets are patched from recorded positions
;; after the layout is final. Jumps and branches with an immediate target are
;; always wide.
;;
;; Anything re-emitted later at a recorded offset, the two halves of `la`
;; and the instruction in a prologue that sizes the frame, has to keep its
;; width. Those use the `-w` emitters.
(define (c-imm6? v) (if (%>= v -32) (%< v 32) nil))
(define (c-reg? r) (if (%>= r 8) (%<= r 15) nil))
(define (c-word-off? o hi)
  (if (%>= o 0) (if (%< o hi) (%= 0 (%logand o 3)) nil) nil))

(define (c-ci a base rd v)
  (half a (%logior base
                       (%logior (%lsh (%logand rd 31) 7)
                                (%logior (%lsh (%logand v 31) 2)
                                         (%lsh (%logand v 32) 7))))))

(define (i-c-addi a rd v) (c-ci a #x0001 rd v))
(define (i-c-li a rd v)   (c-ci a #x4001 rd v))
(define (i-c-mv a rd rs)
  (half a (%logior #x8002 (%logior (%lsh rd 7) (%lsh rs 2)))))
(define (i-c-jr a rs)   (half a (%logior #x8002 (%lsh rs 7))))
(define (i-c-jalr a rs) (half a (%logior #x9002 (%lsh rs 7))))
(define (i-c-lwsp a rd off)
  (half a (%logior #x4002
                       (%logior (%lsh rd 7)
                                (%logior (%lsh (%logand off #x1c) 2)
                                         (%logior (%lsh (%logand off #x20) 7)
                                                  (%lsh (%logand off #xc0) -4)))))))
(define (i-c-swsp a rs off)
  (half a (%logior #xc002
                       (%logior (%lsh rs 2)
                                (%logior (%lsh (%logand off #x3c) 7)
                                         (%lsh (%logand off #xc0) 1))))))
(define (c-mem a base rd rs1 off)
  (half a (%logior base
                       (%logior (%lsh (%- rd 8) 2)
                                (%logior (%lsh (%- rs1 8) 7)
                                         (%logior (%lsh (%logand off #x38) 7)
                                                  (%logior (%lsh (%logand off 4) 4)
                                                           (%lsh (%logand off #x40) -1))))))))
(define (i-c-lw a rd rs1 off) (c-mem a #x4000 rd rs1 off))
(define (i-c-sw a rs2 rs1 off) (c-mem a #xc000 rs2 rs1 off))

;; The wide form, for the places that patch themselves.
(define (i-addi-w a rd rs1 imm) (i-i a rd rs1 imm 0 op-imm))

;; ---------------------------------------------------------------- memory
(define (i-lb a rd rs1 off)  (i-i a rd rs1 off 0 op-load))
(define (i-lh a rd rs1 off)  (i-i a rd rs1 off 1 op-load))
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

;; custom-0 is a word load and a word store with funct3 saying what the base
;; register has to be and the offset saying which slot. car and cdr are
;; offsets 0 and 4 of the same instruction.
(define (i-lref a rd rs1 off)  (i-i a rd rs1 off 0 op-pair))
(define (i-lobj a rd rs1 off)  (i-i a rd rs1 off 1 op-pair))
;; lobj that traps instead of delivering the unbound marker: a variable's
;; value cell.
(define (i-lvar a rd rs1 off)  (i-i a rd rs1 off 2 op-pair))
(define (i-sref a rs2 rs1 off) (i-s a rs1 rs2 off 4 op-pair))
(define (i-sobj a rs2 rs1 off) (i-s a rs1 rs2 off 5 op-pair))

(define (i-car a rd rs1)      (i-lref a rd rs1 0))
(define (i-cdr a rd rs1)      (i-lref a rd rs1 4))
(define (i-set-car a rs2 rs1) (i-sref a rs2 rs1 0))
(define (i-set-cdr a rs2 rs1) (i-sref a rs2 rs1 4))

;; rd, object, index; for the stores rd is the value written.
(define (i-ldx a rd obj idx ty)  (i-r a ty rd obj idx 0 op-index))
(define (i-stx a val obj idx ty) (i-r a ty val obj idx 1 op-index))
(define (i-ldxb a rd obj idx ty)  (i-r a ty rd obj idx 2 op-index))
(define (i-stxb a val obj idx ty) (i-r a ty val obj idx 3 op-index))
;; The same four with a constant index of 0..31 in the rs2 field, the way
;; slli keeps its shift amount there.
(define (i-ldxi a rd obj i ty)  (i-r a ty rd obj i 4 op-index))
(define (i-stxi a val obj i ty) (i-r a ty val obj i 5 op-index))
(define (i-ldxbi a rd obj i ty)  (i-r a ty rd obj i 6 op-index))
(define (i-stxbi a val obj i ty) (i-r a ty val obj i 7 op-index))

;; ---------------------------------------------------------------- fixnums
(define (i-fadd a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 0 op-fixnum))
(define (i-fsub a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 1 op-fixnum))
(define (i-fmul a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 2 op-fixnum))
(define (i-fdiv a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 3 op-fixnum))
(define (i-frem a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 4 op-fixnum))
(define (i-fand a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 5 op-fixnum))
(define (i-for a rd rs1 rs2)  (i-r a #x00 rd rs1 rs2 6 op-fixnum))
(define (i-fxor a rd rs1 rs2) (i-r a #x00 rd rs1 rs2 7 op-fixnum))
;; The same three, trapping on a result that does not fit in 31 bits. The
;; trap handler widens the operation into a bignum and resumes.
(define (i-faddo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 0 op-fixnum))
(define (i-fsubo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 1 op-fixnum))
(define (i-fmulo a rd rs1 rs2) (i-r a #x20 rd rs1 rs2 2 op-fixnum))
(define (i-fsll a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 0 op-fixnum))
(define (i-fsrl a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 1 op-fixnum))
(define (i-fsra a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 2 op-fixnum))
;; The comparisons leave a raw 0 or 1 in rd, the way slt does.
(define (i-flt a rd rs1 rs2)   (i-r a #x01 rd rs1 rs2 3 op-fixnum))
(define (i-fltu a rd rs1 rs2)  (i-r a #x01 rd rs1 rs2 4 op-fixnum))
(define (i-feq a rd rs1 rs2)   (i-r a #x01 rd rs1 rs2 5 op-fixnum))

;; A fixnum against a constant: the instruction doubles the immediate, so the
;; immediate is the constant itself.
(define (i-faddi a rd rs1 imm) (i-i a rd rs1 imm 0 op-tagged))
(define (i-fandi a rd rs1 imm) (i-i a rd rs1 imm 1 op-tagged))
(define (i-fori a rd rs1 imm)  (i-i a rd rs1 imm 2 op-tagged))
;; kind 0 left, 1 right logical, 2 right arithmetic.
(define (i-fshi a rd rs1 kind sh)
  (i-i a rd rs1 (%logior (%lsh kind 5) sh) 3 op-tagged))
;; Memory through a tagged address: the address in rs1 is a fixnum, and a
;; loaded value comes back as one.
(define (i-tlw a rd rs1 off) (i-i a rd rs1 off 4 op-tagged))
(define (i-tlb a rd rs1 off) (i-i a rd rs1 off 5 op-tagged))
(define (i-tsw a rs2 rs1 off) (i-s a rs1 rs2 off 6 op-tagged))
(define (i-tsb a rs2 rs1 off) (i-s a rs1 rs2 off 7 op-tagged))

;; ---------------------------------------------------------------- Zba Zbb Zbs Zicond
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
;; rd <- (rs2 = 0) ? 0 : rs1, and its opposite: a select with no branch.
(define (i-czero-eqz a rd rs1 rs2) (i-r a #x07 rd rs1 rs2 5 op-reg))
(define (i-czero-nez a rd rs1 rs2) (i-r a #x07 rd rs1 rs2 7 op-reg))

;; ---------------------------------------------------------------- system
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
(define (sign12 n) (if (%>= n 2048) (%- n 4096) n))

;; Load a 32-bit constant. Addresses are signed throughout, so a value with
;; the top bit set arrives as a negative number and encodes the same way.
(define (i-li a rd v)
  (if (fits12? v)
      (i-addi a rd $zero v)
      (let* ((lo (%logand v #xfff))
             (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
             (hi (%logand (%lsh (%- v lo-signed) -12) #xfffff)))
        (i-lui a rd hi)
        (if (%= lo-signed 0) nil (i-addi a rd rd lo-signed)))))

;; Load the tagged form of a fixnum, 2v+1. This cannot go through i-li,
;; because 2v+1 does not fit in a fixnum once |v| reaches 2^29, so the lui and
;; addi fields are computed from v and 2v+1 is never formed.
(define (i-li-fixnum a rd v)
  (if (if (%>= v -1024) (%< v 1024) nil)
      (i-addi a rd $zero (%+ (%* 2 v) 1))
      (let* ((lo (%logand (%+ (%* 2 (%logand v 2047)) 1) 4095))
             (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
             ;; 2v+1-lo-signed is 2(v+k) and divisible by 4096, so the high
             ;; field is (v+k)/2048, with nothing overflowing on the way.
             (k (%/ (%- 1 lo-signed) 2))
             (hi (%logand (%/ (%+ v k) 2048) #xfffff)))
        (i-lui a rd hi)
        (if (%= lo-signed 0) nil (i-addi a rd rd lo-signed)))))

;; Store at an absolute address, through a scratch register.
(define (i-sw-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sw a rs $zero addr)
      (begin (i-li a scratch (%- addr (%logand addr #xfff)))
             (i-sw a rs scratch (sign12 (%logand addr #xfff))))))

;; ---------------------------------------------------------------- branches
;; Label-relative forms record a fixup and are patched once every label is
;; placed. Sizes never change, so one pass of patching is enough.
(define (i-branch a f3 rs1 rs2 label)
  (fixup a 'b f3 rs1 rs2 label)
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
  (fixup a 'jal $zero label)
  (enc-j a $zero 0 op-jal))

(define (i-jal a rd label)
  (fixup a 'jal rd label)
  (enc-j a rd 0 op-jal))

;; The address of a label, as auipc and addi. Both halves stay wide:
;; `resolve` rewinds to this offset and writes them again.
(define (i-la a rd label)
  (fixup a 'la rd label)
  (i-auipc a rd 0)
  (i-addi-w a rd rd 0))

;; ---------------------------------------------------------------- resolution
;; Each fixup is re-encoded in place by pointing the emitter at the patch site.
(define (resolve a)
  (let ((fixups (reverse (asm-fixups a))))
    (dolist (f fixups)
      (let* ((kind (%car f))
             (off (cadr f))
             (rest (cddr f)))
        (cond
         ((%eq? kind 'b)
          (let* ((f3 (%car rest)) (rs1 (cadr rest)) (rs2 (caddr rest))
                 (label (cadddr rest))
                 (delta (%- (label-offset a label) off))
                 (save (asm-len a)))
            (if (if (%>= delta -4096) (%< delta 4096) nil)
                nil
                (error "assembler: branch out of range" label delta))
            (set-asm-len! a off)
            (i-b a rs1 rs2 delta f3 op-br)
            (set-asm-len! a save)))
         ((%eq? kind 'jal)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (label-offset a label) off))
                 (save (asm-len a)))
            (if (if (%>= delta -1048576) (%< delta 1048576) nil)
                nil
                (error "assembler: jump out of range" label delta))
            (set-asm-len! a off)
            (enc-j a rd delta op-jal)
            (set-asm-len! a save)))
         ((%eq? kind 'la)
          (let* ((rd (%car rest)) (label (cadr rest))
                 (delta (%- (label-offset a label) off))
                 (lo (%logand delta #xfff))
                 (lo-signed (if (%>= lo 2048) (%- lo 4096) lo))
                 (hi (%logand (%lsh (%- delta lo-signed) -12) #xfffff))
                 (save (asm-len a)))
            (set-asm-len! a off)
            (i-auipc a rd hi)
            (i-addi-w a rd rd lo-signed)
            (set-asm-len! a save)))
         (else (error "assembler: unknown fixup" kind)))))
    (set-asm-fixups! a nil)
    a))

;; ---------------------------------------------------------------- placement
;; Code space is never compacted, so the address a function is placed at is
;; good for the life of the image.
(define (copy-out a addr)
  (let ((len (asm-len a))
        (buf (asm-buf a))
        (i 0))
    (while (%< i len)
      (%st-byte! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1)))
    addr))

;; Place at an address reserved earlier. The reset stub is assembled last,
;; because it refers to everything else, but has to sit at the base of code
;; space, where the processor starts.
(define (place-at a addr)
  (set-asm-origin! a addr)
  (resolve a)
  (copy-out a addr))

(define (place a)
  (resolve a)
  (let ((addr (alloc-code (asm-len a))))
    (set-asm-origin! a addr)
    (copy-out a addr)))

;; The assembled code as a heap object, which is how the collector sees both
;; the machine code and every literal it refers to. The literals list is
;; newest first, so it fills the vector from the far end. The name is what a
;; backtrace prints: every frame saves its caller's code object.
(define (code-object a name)
  (let* ((n (asm-nlits a))
         (v (alloc-object t-code (%+ code-lits n)))
         (i (%- (%+ code-lits n) 1)))
    (%st-fixnum! (%addr-of v) (asm-origin a))       ; raw entry address
    (%st-fixnum! (%+ (%addr-of v) 4) (asm-len a))   ; raw byte length
    (%set-slot! v code-name name)
    (dolist (l (asm-literals a))
      (%set-slot! v i l)
      (set! i (%- i 1)))
    ;; Code space has no headers to walk, so the collector finds code through
    ;; the registry.
    (register-code v)
    v))
