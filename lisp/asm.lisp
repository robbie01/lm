;;; asm.lisp - an assembler for RV32IMC with CHERI and the Lisp instructions.
;;;
;;; The forge's interpreter runs this while the image is built, and the
;;; compiled copy in the image runs it when the machine compiles for itself.
;;;
;;; The machine is always in capability mode, so the encodings here are the
;;; purecap ones: loads and stores take a capability as their base, `c.mv`
;;; moves a whole capability, and the stack is adjusted with `cincoffset`.
;;; Every encoder builds its instruction as one 32-bit fixnum.

(in-package asm)

;; ---------------------------------------------------------------- registers
(defconstant $zero 0)    (defconstant $ra 1)      (defconstant $sp 2)
(defconstant $gp 3)      (defconstant $tp 4)      (defconstant $t0 5)
(defconstant $t1 6)      (defconstant $t2 7)      (defconstant $s0 8)
(defconstant $s1 9)      (defconstant $a0 10)     (defconstant $a1 11)
(defconstant $a2 12)     (defconstant $a3 13)     (defconstant $a4 14)
(defconstant $a5 15)     (defconstant $a6 16)     (defconstant $a7 17)
(defconstant $s2 18)     (defconstant $s3 19)     (defconstant $s4 20)
(defconstant $s5 21)     (defconstant $s6 22)     (defconstant $s7 23)
(defconstant $s8 24)     (defconstant $s9 25)     (defconstant $s10 26)
(defconstant $s11 27)    (defconstant $t3 28)     (defconstant $t4 29)
(defconstant $t5 30)     (defconstant $t6 31)

;; gp is the running task's cons run and tp holds nil, for the life of the
;; machine. Nothing else may use them.

;; ---------------------------------------------------------------- csr numbers
(defconstant csr-mstatus  #x300)
(defconstant csr-mie      #x304)
(defconstant csr-mtvec    #x305)
(defconstant csr-mscratch #x340)
(defconstant csr-mepc     #x341)
(defconstant csr-mcause   #x342)
(defconstant csr-mtval    #x343)
(defconstant csr-mip      #x344)
(defconstant csr-stklim   #x7c0)   ; custom: the lowest address sp may reach
(defconstant csr-gcmode   #x7c1)   ; custom: bit 0 turns the write barrier on
(defconstant csr-cycle    #xc00)
(defconstant csr-cycleh   #xc80)

;; The special capability registers, reached with cspecialrw, are numbered by
;; the generated layout's `scr-*`.

;; ---------------------------------------------------------------- the buffer
;; buf is the output buffer and len the bytes of it used. labels is an alist
;; of (name . byte-offset). fixups is the list of pending relocations, newest
;; first. origin is the address the code was placed at. literals is the list
;; of values the code refers to, newest first, and nlits its length.
;; privileged says the code may use SR: its entry capability carries it.
(defrecord (assembler asm) buf len labels fixups origin literals nlits
  privileged)

(define (make-assembler)
  (let ((a (asm-alloc)))
    (set-asm-buf! a (make-bytes-n 512))
    (set-asm-len! a 0)
    (set-asm-origin! a 0)
    (set-asm-nlits! a 0)
    (set-asm-privileged! a nil)
    a))

;; Record a value the code refers to, and answer its slot in the code object.
;; Code holds no object addresses: it loads an object from the code object's
;; literal slots, so the collector can move the object by updating one slot.
;; A repeated value shares a slot.
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

;; Byte offset of literal i from the code object capability, which s1 holds
;; while a compiled function runs. A literal is loaded with `lc reg, off(s1)`,
;; whose offset reaches 2047.
(define (literal-offset i) (%* value-bytes (%+ code-lits i)))

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

;; A compressed instruction, sixteen bits.
(define (half a h)
  (let ((len (asm-len a)))
    (grow a (%+ len 2))
    (let ((buf (asm-buf a)))
      (%bytes-set! buf len (%logand h 255))
      (%bytes-set! buf (%+ len 1) (%logand (%lsh h -8) 255)))
    (set-asm-len! a (%+ len 2))))

;; A 32-bit instruction, low byte first.
(define (word a w)
  (let ((len (asm-len a)))
    (grow a (%+ len 4))
    (let ((buf (asm-buf a)))
      (%bytes-set! buf len (%logand w 255))
      (%bytes-set! buf (%+ len 1) (%logand (%lsh w -8) 255))
      (%bytes-set! buf (%+ len 2) (%logand (%lsh w -16) 255))
      (%bytes-set! buf (%+ len 3) (%logand (%lsh w -24) 255)))
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
;; Field positions in a 32-bit instruction:
;;   opcode  0..6     rd   7..11    funct3  12..14
;;   rs1     15..19   rs2  20..24   funct7  25..31
(define (enc f7 rs2 rs1 f3 rd op)
  (%logior (%lsh (%logand f7 127) 25)
           (%logior (%lsh (%logand rs2 31) 20)
                    (%logior (%lsh (%logand rs1 31) 15)
                             (%logior (%lsh (%logand f3 7) 12)
                                      (%logior (%lsh (%logand rd 31) 7)
                                               (%logand op 127)))))))

(define (i-r a f7 rd rs1 rs2 f3 op)
  (word a (enc f7 rs2 rs1 f3 rd op)))

;; imm[11:0] occupies bits 20..31.
(define (i-i a rd rs1 imm f3 op)
  (word a (%logior (%lsh (%logand imm #xfff) 20) (enc 0 0 rs1 f3 rd op))))

;; imm[4:0] in bits 7..11, imm[11:5] in bits 25..31.
(define (i-s a rs1 rs2 imm f3 op)
  (word a (enc (%lsh imm -5) rs2 rs1 f3 imm op)))

;; imm[11] in bit 7, imm[4:1] in bits 8..11, imm[10:5] in bits 25..30,
;; imm[12] in bit 31.
(define (i-b a rs1 rs2 imm f3 op)
  (word a (enc (%logior (%logand (%lsh imm -5) 63)
                        (%lsh (%logand (%lsh imm -12) 1) 6))
               rs2 rs1 f3
               (%logior (%logand (%lsh imm -11) 1)
                        (%lsh (%logand (%lsh imm -1) 15) 1))
               op)))

;; imm20 occupies bits 12..31.
(define (i-u a rd imm20 op)
  (word a (%logior (%lsh (%logand imm20 #xfffff) 12)
                   (%logior (%lsh (%logand rd 31) 7) op))))

;; imm[19:12] in bits 12..19, imm[11] in bit 20, imm[10:1] in bits 21..30,
;; imm[20] in bit 31, assembled as a U-type field.
(define (enc-j a rd imm op)
  (let ((f (%logior (%logand (%lsh imm -12) 255)
                    (%logior (%lsh (%logand (%lsh imm -11) 1) 8)
                             (%logior (%lsh (%logand (%lsh imm -1) 1023) 9)
                                      (%lsh (%logand (%lsh imm -20) 1) 19))))))
    (i-u a rd f op)))

;; ---------------------------------------------------------------- opcodes
(defconstant op-load  #x03)
(defconstant op-imm   #x13)
(defconstant op-auipc #x17)
(defconstant op-store #x23)
(defconstant op-reg   #x33)
(defconstant op-lui   #x37)
(defconstant op-br    #x63)
(defconstant op-jalr  #x67)
(defconstant op-jal   #x6f)
(defconstant op-sys   #x73)
;; custom-0: references. Loads, stores, a call and branches that check the
;; kind of value each operand holds as they use it.
(defconstant op-ref   #x0b)
;; custom-1: indexed access. funct7 carries the type the object has to be, so
;; one instruction checks the tag, the type, the index and the bound.
(defconstant op-index #x2b)
;; The CHERI instructions, in the custom-2 slot.
(defconstant op-cheri #x5b)
;; custom-3: fixnum arithmetic with every operand checked.
(defconstant op-fixnum #x7b)

;; ---------------------------------------------------------------- RV32I
(define (i-lui a rd imm20)   (i-u a rd imm20 op-lui))
;; auipcc: PCC with its address moved.
(define (i-auipc a rd imm20) (i-u a rd imm20 op-auipc))

;; addi is integer arithmetic, and its result is untagged. sp always holds a
;; capability, so adjusting it is cincoffsetimm's work, and an addi that
;; writes sp is refused here rather than found as a fault at run time.
(define (not-sp rd)
  (if (%= rd $sp)
      (error "assembler: addi would leave sp an integer; use cincoffsetimm")
      rd))

(define (i-addi a rd rs1 imm)
  (not-sp rd)
  (cond
   ((if (%= rs1 $zero) (if (%> rd 0) (c-imm6? imm) nil) nil) (i-c-li a rd imm))
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
;; An offset in 0..hi-1 with none of the bits of mask set.
(define (c-off? o hi mask)
  (if (%>= o 0) (if (%< o hi) (%= 0 (%logand o mask)) nil) nil))
;; The immediates of c.addi16sp and c.addi4spn.
(define (c-sp16? v)
  (if (%= v 0) nil (if (%>= v -512) (if (%< v 512) (%= 0 (%logand v 15)) nil) nil)))
(define (c-sp4? v) (if (%> v 0) (if (%< v 1024) (%= 0 (%logand v 3)) nil) nil))

(define (c-ci a base rd v)
  (half a (%logior base
                   (%logior (%lsh (%logand rd 31) 7)
                            (%logior (%lsh (%logand v 31) 2)
                                     (%lsh (%logand v 32) 7))))))

(define (i-c-addi a rd v) (c-ci a #x0001 rd v))
(define (i-c-li a rd v)   (c-ci a #x4001 rd v))
;; c.mv is cmove: the whole capability.
(define (i-c-mv a rd rs)
  (half a (%logior #x8002 (%logior (%lsh rd 7) (%lsh rs 2)))))
(define (i-c-jr a rs)   (half a (%logior #x8002 (%lsh rs 7))))
(define (i-c-jalr a rs) (half a (%logior #x9002 (%lsh rs 7))))
;; c.addi16sp and c.addi4spn are cincoffset on csp.
(define (i-c-addi16sp a v)
  (half a (%logior #x6101
                   (%logior (%lsh (%logand v #x200) 3)
                            (%logior (%lsh (%logand v #x10) 2)
                                     (%logior (%lsh (%logand v #x40) -1)
                                              (%logior (%lsh (%logand v #x180) -4)
                                                       (%lsh (%logand v #x20) -3))))))))
(define (i-c-addi4spn a rd v)
  (half a (%logior (%lsh (%- rd 8) 2)
                   (%logior (%lsh (%logand v #x3c0) 1)
                            (%logior (%lsh (%logand v #x30) 7)
                                     (%logior (%lsh (%logand v 4) 4)
                                              (%lsh (%logand v 8) 2)))))))
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
;; c.lcsp and c.scsp, in the slots of c.flwsp and c.fswsp, with the offsets
;; of RV64C's c.ldsp and c.sdsp.
(define (i-c-lcsp a rd off)
  (half a (%logior #x6002
                   (%logior (%lsh rd 7)
                            (%logior (%lsh (%logand off #x18) 2)
                                     (%logior (%lsh (%logand off #x20) 7)
                                              (%lsh (%logand off #x1c0) -4)))))))
(define (i-c-scsp a rs off)
  (half a (%logior #xe002
                   (%logior (%lsh rs 2)
                            (%logior (%lsh (%logand off #x38) 7)
                                     (%lsh (%logand off #x1c0) 1))))))
(define (c-mem a base rd rs1 off)
  (half a (%logior base
                   (%logior (%lsh (%- rd 8) 2)
                            (%logior (%lsh (%- rs1 8) 7)
                                     (%logior (%lsh (%logand off #x38) 7)
                                              (%logior (%lsh (%logand off 4) 4)
                                                       (%lsh (%logand off #x40) -1))))))))
(define (i-c-lw a rd rs1 off) (c-mem a #x4000 rd rs1 off))
(define (i-c-sw a rs2 rs1 off) (c-mem a #xc000 rs2 rs1 off))
;; c.lc and c.sc, in the slots of c.flw and c.fsw, with the offsets of
;; RV64C's c.ld and c.sd.
(define (c-cap-mem a base rd rs1 off)
  (half a (%logior base
                   (%logior (%lsh (%- rd 8) 2)
                            (%logior (%lsh (%- rs1 8) 7)
                                     (%logior (%lsh (%logand off #x38) 7)
                                              (%lsh (%logand off #xc0) -1)))))))
(define (i-c-lc a rd rs1 off) (c-cap-mem a #x6000 rd rs1 off))
(define (i-c-sc a rs2 rs1 off) (c-cap-mem a #xe000 rs2 rs1 off))

;; The wide forms, for the places that patch themselves.
(define (i-addi-w a rd rs1 imm) (not-sp rd) (i-i a rd rs1 imm 0 op-imm))
(define (i-cincoffsetimm-w a cd cs1 imm) (i-i a cd cs1 imm 1 op-cheri))

;; ---------------------------------------------------------------- memory
;; The base register of a load or store is the capability that authorises
;; it. Base x0 is the exception: the offset is then an integer address,
;; reached through DDC, which only privileged code may do.
(define (i-lb a rd rs1 off)  (i-i a rd rs1 off 0 op-load))
(define (i-lh a rd rs1 off)  (i-i a rd rs1 off 1 op-load))
(define (i-lw a rd rs1 off)
  (cond
   ((if (%= rs1 $sp) (if (%> rd 0) (c-off? off 256 3) nil) nil)
    (i-c-lwsp a rd off))
   ((if (c-reg? rd) (if (c-reg? rs1) (c-off? off 128 3) nil) nil)
    (i-c-lw a rd rs1 off))
   (else (i-i a rd rs1 off 2 op-load))))
(define (i-lc a rd rs1 off)
  (cond
   ((if (%= rs1 $sp) (if (%> rd 0) (c-off? off 512 7) nil) nil)
    (i-c-lcsp a rd off))
   ((if (c-reg? rd) (if (c-reg? rs1) (c-off? off 256 7) nil) nil)
    (i-c-lc a rd rs1 off))
   (else (i-i a rd rs1 off 3 op-load))))
(define (i-lbu a rd rs1 off) (i-i a rd rs1 off 4 op-load))
(define (i-lhu a rd rs1 off) (i-i a rd rs1 off 5 op-load))
(define (i-sb a rs2 rs1 off) (i-s a rs1 rs2 off 0 op-store))
(define (i-sh a rs2 rs1 off) (i-s a rs1 rs2 off 1 op-store))
(define (i-sw a rs2 rs1 off)
  (cond
   ((if (%= rs1 $sp) (c-off? off 256 3) nil) (i-c-swsp a rs2 off))
   ((if (c-reg? rs2) (if (c-reg? rs1) (c-off? off 128 3) nil) nil)
    (i-c-sw a rs2 rs1 off))
   (else (i-s a rs1 rs2 off 2 op-store))))
(define (i-sc a rs2 rs1 off)
  (cond
   ((if (%= rs1 $sp) (c-off? off 512 7) nil) (i-c-scsp a rs2 off))
   ((if (c-reg? rs2) (if (c-reg? rs1) (c-off? off 256 7) nil) nil)
    (i-c-sc a rs2 rs1 off))
   (else (i-s a rs1 rs2 off 3 op-store))))

;; The target is cs1, unsealed if it is a sentry; the link is a sentry.
(define (i-jalr a rd rs1 off)
  (cond
   ((if (%= off 0) (if (%> rs1 0) (%= rd 0) nil) nil) (i-c-jr a rs1))
   ((if (%= off 0) (if (%> rs1 0) (%= rd $ra) nil) nil) (i-c-jalr a rs1))
   (else (i-i a rd rs1 off 0 op-jalr))))

;; ---------------------------------------------------------------- CHERI
(define (cap-r a f7 rd rs1 rs2) (i-r a f7 rd rs1 rs2 0 op-cheri))
;; The one-operand forms: the rs2 field says which.
(define (cap-1 a sel rd rs1) (i-r a #x7f rd rs1 sel 0 op-cheri))

(define (i-cspecialrw a cd scr cs1)     (cap-r a #x01 cd cs1 scr))
(define (i-csetbounds a cd cs1 rs2)      (cap-r a #x08 cd cs1 rs2))
(define (i-csetboundsexact a cd cs1 rs2) (cap-r a #x09 cd cs1 rs2))
(define (i-cseal a cd cs1 cs2)           (cap-r a #x0b cd cs1 cs2))
(define (i-cunseal a cd cs1 cs2)         (cap-r a #x0c cd cs1 cs2))
(define (i-candperm a cd cs1 rs2)        (cap-r a #x0d cd cs1 rs2))
(define (i-csetaddr a cd cs1 rs2)        (cap-r a #x10 cd cs1 rs2))
(define (i-cincoffset a cd cs1 rs2)      (cap-r a #x11 cd cs1 rs2))
(define (i-csub a rd cs1 cs2)            (cap-r a #x14 rd cs1 cs2))
(define (i-csethigh a cd cs1 rs2)        (cap-r a #x16 cd cs1 rs2))
(define (i-cbuildcap a cd cs1 cs2)       (cap-r a #x1d cd cs1 cs2))
(define (i-ctestsubset a rd cs1 cs2)     (cap-r a #x20 rd cs1 cs2))
(define (i-cseqx a rd cs1 cs2)           (cap-r a #x21 rd cs1 cs2))

(define (i-cgetperm a rd cs1)   (cap-1 a #x00 rd cs1))
(define (i-cgettype a rd cs1)   (cap-1 a #x01 rd cs1))
(define (i-cgetbase a rd cs1)   (cap-1 a #x02 rd cs1))
(define (i-cgetlen a rd cs1)    (cap-1 a #x03 rd cs1))
(define (i-cgettag a rd cs1)    (cap-1 a #x04 rd cs1))
(define (i-cgetsealed a rd cs1) (cap-1 a #x05 rd cs1))
(define (i-cgetoffset a rd cs1) (cap-1 a #x06 rd cs1))
(define (i-crrl a rd rs1)       (cap-1 a #x08 rd rs1))
(define (i-cram a rd rs1)       (cap-1 a #x09 rd rs1))
(define (i-cmove a cd cs1)      (cap-1 a #x0a cd cs1))
(define (i-ccleartag a cd cs1)  (cap-1 a #x0b cd cs1))
(define (i-cjalr a cd cs1)      (cap-1 a #x0c cd cs1))
(define (i-cgetaddr a rd cs1)   (cap-1 a #x0f rd cs1))
(define (i-csealentry a cd cs1) (cap-1 a #x11 cd cs1))
(define (i-cgethigh a rd cs1)   (cap-1 a #x17 rd cs1))
(define (i-cgettop a rd cs1)    (cap-1 a #x18 rd cs1))
;; Seal a closure object as a closure, for jcl to enter.
(define (i-csealclo a cd cs1)   (cap-1 a #x1c cd cs1))

;; The stack and the frame are adjusted with this, so that they stay
;; capabilities. On sp it has the sixteen-bit forms c.addi16sp and
;; c.addi4spn.
(define (i-cincoffsetimm a cd cs1 imm)
  (cond
   ((if (%= cd $sp) (if (%= cs1 $sp) (c-sp16? imm) nil) nil) (i-c-addi16sp a imm))
   ((if (%= cs1 $sp) (if (c-reg? cd) (c-sp4? imm) nil) nil) (i-c-addi4spn a cd imm))
   (else (i-cincoffsetimm-w a cd cs1 imm))))
;; The length is unsigned, 0..4095.
(define (i-csetboundsimm a cd cs1 uimm) (i-i a cd cs1 uimm 2 op-cheri))

;; Memory by integer address, through DDC: rs1 is the address. A store's
;; rd field and a load's rs2 field say the width.
(define (ddc-load a sel rd rs1)    (cap-r a #x7d rd rs1 sel))
(define (ddc-store a sel rs2 rs1)  (cap-r a #x7c sel rs1 rs2))
(define (i-lb-ddc a rd rs1)  (ddc-load a 0 rd rs1))
(define (i-lh-ddc a rd rs1)  (ddc-load a 1 rd rs1))
(define (i-lw-ddc a rd rs1)  (ddc-load a 2 rd rs1))
(define (i-lc-ddc a rd rs1)  (ddc-load a 3 rd rs1))
(define (i-lbu-ddc a rd rs1) (ddc-load a 4 rd rs1))
(define (i-lhu-ddc a rd rs1) (ddc-load a 5 rd rs1))
(define (i-sb-ddc a rs2 rs1) (ddc-store a 0 rs2 rs1))
(define (i-sh-ddc a rs2 rs1) (ddc-store a 1 rs2 rs1))
(define (i-sw-ddc a rs2 rs1) (ddc-store a 2 rs2 rs1))
(define (i-sc-ddc a rs2 rs1) (ddc-store a 3 rs2 rs1))

;; ---------------------------------------------------------------- Xlm
;; custom-0. car and cdr are offsets 0 and 8 of lref, and set-car and
;; set-cdr the same offsets of sref. lvar is the load of a symbol's value
;; slot that traps on the unbound marker.
(define (i-lref a rd rs1 off)  (i-i a rd rs1 off 0 op-ref))
(define (i-vkind a rd rs1)     (i-i a rd rs1 0 1 op-ref))
(define (i-lvar a rd rs1 off)  (i-i a rd rs1 off 2 op-ref))
;; Enter the closure in rs1: rs1 is left holding it unsealed, rd the return
;; sentry.
(define (i-jcl a rd rs1)       (i-i a rd rs1 0 3 op-ref))
(define (i-sref a rs2 rs1 off) (i-s a rs1 rs2 off 4 op-ref))
;; The length of an object of header type ty, or of any type for 0.
(define (i-lhdr a rd rs1 ty)   (i-i a rd rs1 ty 5 op-ref))

(define (i-car a rd rs1)      (i-lref a rd rs1 0))
(define (i-cdr a rd rs1)      (i-lref a rd rs1 value-bytes))
(define (i-set-car a rs2 rs1) (i-sref a rs2 rs1 0))
(define (i-set-cdr a rs2 rs1) (i-sref a rs2 rs1 value-bytes))

;; custom-1. rd, object, index; for the stores rd is the value written.
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

;; custom-3. Every operand is checked to be a fixnum. The o forms trap on a
;; result that does not fit in 32 bits, and the trap handler widens the
;; operation into a bignum and resumes.
(define (i-faddi a rd rs1 imm)  (i-i a rd rs1 imm 0 op-fixnum))
(define (i-faddio a rd rs1 imm) (i-i a rd rs1 imm 1 op-fixnum))
(define (i-fandi a rd rs1 imm)  (i-i a rd rs1 imm 2 op-fixnum))
(define (i-fori a rd rs1 imm)   (i-i a rd rs1 imm 3 op-fixnum))
;; kind 0 left, 1 right logical, 2 right arithmetic.
(define (i-fshi a rd rs1 kind sh)
  (i-i a rd rs1 (%logior (%lsh kind 5) (%logand sh 31)) 4 op-fixnum))

(define (fop a f7 rd rs1 rs2) (i-r a f7 rd rs1 rs2 5 op-fixnum))
(define (i-fadd a rd rs1 rs2)  (fop a #x00 rd rs1 rs2))
(define (i-fsub a rd rs1 rs2)  (fop a #x01 rd rs1 rs2))
(define (i-fmul a rd rs1 rs2)  (fop a #x02 rd rs1 rs2))
(define (i-fdiv a rd rs1 rs2)  (fop a #x03 rd rs1 rs2))
(define (i-frem a rd rs1 rs2)  (fop a #x04 rd rs1 rs2))
(define (i-fand a rd rs1 rs2)  (fop a #x05 rd rs1 rs2))
(define (i-for a rd rs1 rs2)   (fop a #x06 rd rs1 rs2))
(define (i-fxor a rd rs1 rs2)  (fop a #x07 rd rs1 rs2))
(define (i-faddo a rd rs1 rs2) (fop a #x08 rd rs1 rs2))
(define (i-fsubo a rd rs1 rs2) (fop a #x09 rd rs1 rs2))
(define (i-fmulo a rd rs1 rs2) (fop a #x0a rd rs1 rs2))
(define (i-fsll a rd rs1 rs2)  (fop a #x10 rd rs1 rs2))
(define (i-fsrl a rd rs1 rs2)  (fop a #x11 rd rs1 rs2))
(define (i-fsra a rd rs1 rs2)  (fop a #x12 rd rs1 rs2))
;; The comparisons leave the fixnum 0 or 1 in rd.
(define (i-flt a rd rs1 rs2)   (fop a #x13 rd rs1 rs2))
(define (i-fltu a rd rs1 rs2)  (fop a #x14 rd rs1 rs2))
(define (i-feq a rd rs1 rs2)   (fop a #x15 rd rs1 rs2))

;; An untagged value of kind from-kind (63 for any) given the metadata
;; to-kind, its address kept: char->integer is from 1 to 0.
(define (i-retag a rd rs1 from-kind to-kind)
  (i-i a rd rs1 (%logior (%lsh (%logand from-kind 63) 6) (%logand to-kind 63))
       7 op-fixnum))

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
;; A whole capability, tag and all.
(define (i-mv a rd rs)
  (if (if (%> rd 0) (%> rs 0) nil) (i-c-mv a rd rs) (i-cmove a rd rs)))
(define (i-neg a rd rs) (i-sub a rd $zero rs))
(define (i-not a rd rs) (i-xori a rd rs -1))
(define (i-seqz a rd rs) (i-sltiu a rd rs 1))
(define (i-snez a rd rs) (i-sltu a rd $zero rs))

(define (fits12? n) (if (%>= n -2048) (%< n 2048) nil))
(define (sign12 n) (if (%>= n 2048) (%- n 4096) n))

;; Load a 32-bit constant, which is also the fixnum of that value. A value
;; with the top bit set is a negative fixnum and encodes the same way.
(define (i-li a rd v)
  (if (fits12? v)
      (i-addi a rd $zero v)
      (let* ((lo-signed (sign12 (%logand v #xfff)))
             (hi (%logand (%lsh (%- v lo-signed) -12) #xfffff)))
        (i-lui a rd hi)
        (if (%= lo-signed 0) nil (i-addi a rd rd lo-signed)))))

;; Memory at an absolute address. Base x0 reaches the low 2 KiB through DDC
;; in one instruction; anywhere else the address is formed in a register and
;; reached with the DDC form. A load forms it in its own destination; a store
;; needs a scratch register. The lc and sc forms move an 8-byte value, as the
;; low globals that hold one are.
(define (i-lw-abs a rd addr)
  (if (fits12? addr)
      (i-lw a rd $zero addr)
      (begin (i-li a rd addr) (i-lw-ddc a rd rd))))
(define (i-lc-abs a rd addr)
  (if (fits12? addr)
      (i-lc a rd $zero addr)
      (begin (i-li a rd addr) (i-lc-ddc a rd rd))))
(define (i-sw-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sw a rs $zero addr)
      (begin (i-li a scratch addr) (i-sw-ddc a rs scratch))))
(define (i-sc-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sc a rs $zero addr)
      (begin (i-li a scratch addr) (i-sc-ddc a rs scratch))))

;; ---------------------------------------------------------------- branches
;; Label-relative forms record a fixup and are patched once every label is
;; placed. Sizes never change, so one pass of patching is enough.
(define (branch a op f3 rs1 rs2 label)
  (fixup a 'b op f3 rs1 rs2 label)
  (i-b a rs1 rs2 0 f3 op))

(define (i-branch a f3 rs1 rs2 label) (branch a op-br f3 rs1 rs2 label))
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
;; Identity: tag, metadata and address. A null test is beqx against tp.
(define (i-beqx a rs1 rs2 label) (branch a op-ref 6 rs1 rs2 label))
(define (i-bnex a rs1 rs2 label) (branch a op-ref 7 rs1 rs2 label))

(define (i-j a label)
  (fixup a 'jal $zero label)
  (enc-j a $zero 0 op-jal))

(define (i-jal a rd label)
  (fixup a 'jal rd label)
  (enc-j a rd 0 op-jal))

;; A capability to a label, derived from PCC by auipcc and cincoffsetimm.
;; Both halves stay wide: `resolve` rewinds to this offset and writes them
;; again.
(define (i-la a rd label)
  (fixup a 'la rd label)
  (i-auipc a rd 0)
  (i-cincoffsetimm-w a rd rd 0))

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
          (let* ((op (%car rest)) (f3 (cadr rest)) (rs1 (caddr rest))
                 (rs2 (cadddr rest)) (label (list-ref rest 4))
                 (delta (%- (label-offset a label) off))
                 (save (asm-len a)))
            (if (if (%>= delta -4096) (%< delta 4096) nil)
                nil
                (error "assembler: branch out of range" label delta))
            (set-asm-len! a off)
            (i-b a rs1 rs2 delta f3 op)
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
                 (lo-signed (sign12 (%logand delta #xfff)))
                 (hi (%logand (%lsh (%- delta lo-signed) -12) #xfffff))
                 (save (asm-len a)))
            (set-asm-len! a off)
            (i-auipc a rd hi)
            (i-cincoffsetimm-w a rd rd lo-signed)
            (set-asm-len! a save)))
         (else (error "assembler: unknown fixup" kind)))))
    (set-asm-fixups! a nil)
    a))

;; ---------------------------------------------------------------- placement
;; A function's machine code is an object of its own, a text: bytes, in which
;; no capability can be stored. What reaches it is its entry, a capability
;; with EX bounded exactly to the code, and the return addresses into it,
;; each of which keeps the text alive as any capability keeps the object it
;; lies in. A jump within the code is relative to it, so the text can be
;; anywhere, and the forge slides it with the rest of object space.

;; The bytes placed code occupies: its length rounded up to one that a
;; capability can bound exactly. The allocator aligns the text to match.
(define (code-size a) (%rrl (asm-len a)))

;; The capability that enters placed code: bounds exactly its bytes, EX, and
;; SR as well when the code is privileged.
(define (entry-capability a)
  (unsafe
  (%cap-and-perms
   (%cap-bounds-exact (%from-addr (asm-origin a)) (code-size a))
   (if (asm-privileged a) (%logior perm-ex perm-sr) perm-ex))))

;; The code into a fresh text, through the text's own capability: a word at
;; a time, then the last bytes one by one.
(define (copy-into a text)
  (let ((len (asm-len a)) (buf (asm-buf a)) (i 0))
    (while (%<= (%+ i 4) len)
      (%cap-st-word! text i (%cap-ld-word buf i))
      (set! i (%+ i 4)))
    (while (%< i len)
      (%cap-st-byte! text i (%bytes-ref buf i))
      (set! i (%+ i 1)))))

;; Place in a fresh text, and answer the entry capability. The text's own
;; capability goes no further than this.
(define (place a)
  (resolve a)
  (let ((text (alloc-object t-text (asm-len a))))
    (copy-into a text)
    (set-asm-origin! a (%addr-of text))
    (entry-capability a)))

;; Place at a fixed address, by number through DDC, and answer the address.
;; The reset stub is assembled last, because it refers to everything else,
;; and has to sit at the reset vector, where the processor starts with the
;; root in PCC.
(define (place-at a addr)
  (unsafe
  (set-asm-origin! a addr)
  (resolve a)
  (let ((len (asm-len a)) (buf (asm-buf a)) (i 0))
    (while (%< i len)
      (%st-byte! (%+ addr i) (%bytes-ref buf i))
      (set! i (%+ i 1))))
  addr))

;; The placed code as a heap object, which is how the collector sees every
;; literal it refers to: slot 0 the entry capability, then the name, then
;; the literals. The literals list is newest first, so it fills the object
;; from the far end. The name is what a backtrace prints: every frame saves
;; its caller's code object.
(define (code-object a name)
  (unsafe
  (let* ((n (asm-nlits a))
         (v (alloc-object t-code (%+ code-lits n)))
         (i (%- (%+ code-lits n) 1)))
    (%set-slot! v code-entry (entry-capability a))
    (%set-slot! v code-name name)
    (dolist (l (asm-literals a))
      (%set-slot! v i l)
      (set! i (%- i 1)))
    v)))
