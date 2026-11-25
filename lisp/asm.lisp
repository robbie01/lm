;;; asm.lisp - an assembler for RV32IMC with RVY and the Lisp instructions.
;;;
;;; The forge's interpreter runs this while the image is built, and the
;;; compiled copy in the image runs it when the machine compiles for itself.
;;;
;;; The machine is always in RVY's capability mode, so the encodings here are
;;; the purecap ones: loads and stores take a capability as their base, `c.mv`
;;; moves a whole capability, and the stack is adjusted with `yaddi`. The
;;; encoders are named `i-` and the mnemonic, RVY's for its instructions.
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
(defconstant csr-mtidc    #x37f)
(defconstant csr-utidc    #x07f)
(defconstant csr-stklim   #x7c0)   ; custom: the lowest address sp may reach
(defconstant csr-gcmode   #x7c1)   ; custom: bit 0 turns the write barrier on
(defconstant csr-ddc      #x7c2)   ; custom: DDC, the default data capability
(defconstant csr-cycle    #xc00)
(defconstant csr-cycleh   #xc80)

;; `mtvec`, `mscratch`, `mepc`, the thread identifiers and DDC hold
;; capabilities: a CSR instruction reads one whole, `csrrw` writes one
;; whole, and the others write its address.

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
;; while a compiled function runs. A literal is loaded with `ly reg, off(s1)`,
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
;; RVY-A, the old custom-3: every capability instruction RVY defines.
(defconstant op-rvy   #x7b)
;; custom-0: Xlm, the Lisp instructions, each a capability operation and a
;; check of the kind of value an operand holds.
(defconstant op-xlm   #x0b)

;; ---------------------------------------------------------------- RV32I
(define (i-lui a rd imm20)   (i-u a rd imm20 op-lui))
;; auipc: PCC with its address moved.
(define (i-auipc a rd imm20) (i-u a rd imm20 op-auipc))

;; addi is integer arithmetic, and its result is untagged. sp always holds a
;; capability, so adjusting it is yaddi's work, and an addi that writes sp
;; is refused here rather than found as a fault at run time.
(define (not-sp rd)
  (if (%= rd $sp)
      (error "assembler: addi would leave sp an integer; use yaddi")
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
;; c.mv is C.YMV: the whole capability.
(define (i-c-mv a rd rs)
  (half a (%logior #x8002 (%logior (%lsh rd 7) (%lsh rs 2)))))
(define (i-c-jr a rs)   (half a (%logior #x8002 (%lsh rs 7))))
(define (i-c-jalr a rs) (half a (%logior #x9002 (%lsh rs 7))))
;; c.addi16sp and c.addi4spn are yaddi on csp.
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
;; c.lysp and c.sysp, in the slots of c.flwsp and c.fswsp, with the offsets
;; of RV64C's c.ldsp and c.sdsp.
(define (i-c-lysp a rd off)
  (half a (%logior #x6002
                   (%logior (%lsh rd 7)
                            (%logior (%lsh (%logand off #x18) 2)
                                     (%logior (%lsh (%logand off #x20) 7)
                                              (%lsh (%logand off #x1c0) -4)))))))
(define (i-c-sysp a rs off)
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
;; c.ly and c.sy, in the slots of c.flw and c.fsw, with the offsets of
;; RV64C's c.ld and c.sd.
(define (c-cap-mem a base rd rs1 off)
  (half a (%logior base
                   (%logior (%lsh (%- rd 8) 2)
                            (%logior (%lsh (%- rs1 8) 7)
                                     (%logior (%lsh (%logand off #x38) 7)
                                              (%lsh (%logand off #xc0) -1)))))))
(define (i-c-ly a rd rs1 off) (c-cap-mem a #x6000 rd rs1 off))
(define (i-c-sy a rs2 rs1 off) (c-cap-mem a #xe000 rs2 rs1 off))

;; The wide forms, for the places that patch themselves.
(define (i-addi-w a rd rs1 imm) (not-sp rd) (i-i a rd rs1 imm 0 op-imm))
(define (i-yaddi-w a cd cs1 imm) (i-i a cd cs1 imm 4 op-rvy))

;; ---------------------------------------------------------------- memory
;; The base register of a load or store is the capability that authorises
;; it. Base x0, which RVY reserves, is Xlm's integer addressing: the offset
;; is then an integer address, reached through DDC, which only privileged
;; code may do.
(define (i-lb a rd rs1 off)  (i-i a rd rs1 off 0 op-load))
(define (i-lh a rd rs1 off)  (i-i a rd rs1 off 1 op-load))
(define (i-lw a rd rs1 off)
  (cond
   ((if (%= rs1 $sp) (if (%> rd 0) (c-off? off 256 3) nil) nil)
    (i-c-lwsp a rd off))
   ((if (c-reg? rd) (if (c-reg? rs1) (c-off? off 128 3) nil) nil)
    (i-c-lw a rd rs1 off))
   (else (i-i a rd rs1 off 2 op-load))))
;; ly and sy move a whole capability, tag and all.
(define (i-ly a rd rs1 off)
  (cond
   ((if (%= rs1 $sp) (if (%> rd 0) (c-off? off 512 7) nil) nil)
    (i-c-lysp a rd off))
   ((if (c-reg? rd) (if (c-reg? rs1) (c-off? off 256 7) nil) nil)
    (i-c-ly a rd rs1 off))
   (else (i-i a rd rs1 off 1 op-rvy))))
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
(define (i-sy a rs2 rs1 off)
  (cond
   ((if (%= rs1 $sp) (c-off? off 512 7) nil) (i-c-sysp a rs2 off))
   ((if (c-reg? rs2) (if (c-reg? rs1) (c-off? off 256 7) nil) nil)
    (i-c-sy a rs2 rs1 off))
   (else (i-s a rs1 rs2 off 2 op-rvy))))

;; The target is cs1, unsealed if it is a sentry; the link is a sentry.
(define (i-jalr a rd rs1 off)
  (cond
   ((if (%= off 0) (if (%> rs1 0) (%= rd 0) nil) nil) (i-c-jr a rs1))
   ((if (%= off 0) (if (%> rs1 0) (%= rd $ra) nil) nil) (i-c-jalr a rs1))
   (else (i-i a rd rs1 off 0 op-jalr))))

;; ---------------------------------------------------------------- RVY
;; R-type on RVY-A, funct7 choosing; the two-operand forms are funct7 #x7a
;; (#x78 for yamask) with the operation in the rs2 field.
(define (y-r a f7 rd rs1 rs2) (i-r a f7 rd rs1 rs2 0 op-rvy))
(define (y-1 a sel rd rs1) (i-r a #x7a rd rs1 sel 0 op-rvy))

(define (i-yhiw a cd rs1 rs2)     (y-r a #x01 cd rs1 rs2))
(define (i-ysh1add a cd rs1 cs2)  (y-r a #x05 cd rs1 cs2))
(define (i-ysh2add a cd rs1 cs2)  (y-r a #x0d cd rs1 cs2))
(define (i-ysh3add a cd rs1 cs2)  (y-r a #x15 cd rs1 cs2))
(define (i-yeq a rd cs1 cs2)      (y-r a #x06 rd cs1 cs2))
(define (i-yunseals a cd cs1 cs2) (y-r a #x07 cd cs1 cs2))
(define (i-yaddrw a cd cs1 rs2)   (y-r a #x0b cd cs1 rs2))
(define (i-yss a rd cs1 cs2)      (y-r a #x0e rd cs1 cs2))
(define (i-ybld a cd cs1 cs2)     (y-r a #x0f cd cs1 cs2))
;; rs2 is a mask of the permissions to clear.
(define (i-ypermc a cd cs1 rs2)   (y-r a #x13 cd cs1 rs2))
;; The source is cs2: rs1 is x0 for a sentry, and the authority otherwise.
(define (i-yseale a cd cs2)       (y-r a #x17 cd $zero cs2))
(define (i-ysealt a cd cs1 cs2)   (y-r a #x17 cd cs1 cs2))
(define (i-yunsealt a cd cs1 cs2) (y-r a #x1f cd cs1 cs2))
;; ybndsw is exact and ybndsrw rounds outward.
(define (i-ybndsw a cd cs1 rs2)   (y-r a #x1b cd cs1 rs2))
(define (i-ybndsrw a cd cs1 rs2)  (y-r a #x23 cd cs1 rs2))
;; yadd by x0 is ymv.
(define (i-yadd a cd cs1 rs2)
  (if (%= rs2 $zero) (error "assembler: yadd by x0 is ymv") (y-r a #x03 cd cs1 rs2)))
(define (i-ymv a cd cs1)          (y-r a #x03 cd cs1 $zero))
(define (i-yamask a rd rs1)       (i-r a #x78 rd rs1 0 0 op-rvy))

(define (i-ybaser a rd cs1) (y-1 a 0 rd cs1))
(define (i-ypermr a rd cs1) (y-1 a 1 rd cs1))
(define (i-ytopr a rd cs1)  (y-1 a 2 rd cs1))
(define (i-ylenr a rd cs1)  (y-1 a 3 rd cs1))
(define (i-ytagr a rd cs1)  (y-1 a 4 rd cs1))
(define (i-ytyper a rd cs1) (y-1 a 5 rd cs1))
(define (i-yhir a rd cs1)   (y-1 a 7 rd cs1))

;; The stack and the frame are adjusted with this, so that they stay
;; capabilities. On sp it has the sixteen-bit forms c.addi16sp and
;; c.addi4spn.
(define (i-yaddi a cd cs1 imm)
  (cond
   ((if (%= cd $sp) (if (%= cs1 $sp) (c-sp16? imm) nil) nil) (i-c-addi16sp a imm))
   ((if (%= cs1 $sp) (if (c-reg? cd) (c-sp4? imm) nil) nil) (i-c-addi4spn a cd imm))
   (else (i-yaddi-w a cd cs1 imm))))

;; Exact bounds of a written-down length, which must be one ybndswi's nine
;; bits encode: 1 to 255, 256 to 504 by eight, 512 to 4080 by sixteen, or
;; 4096.
(define (ybndswi-imm len)
  (cond ((%= len 4096) 0)
        ((if (%> len 0) (%< len 256) nil) len)
        ((if (%< len 512) (%= 0 (%logand len 7)) nil)
         (%logior #x100 (%logior (%logand (%lsh len -4) 15) (%lsh (%logand (%lsh len -3) 1) 4))))
        ((if (%< len 4096) (%= 0 (%logand len 15)) nil) (%logior #x100 (%lsh len -4)))
        (else (error "assembler: ybndswi has no encoding for" len))))
(define (i-ybndswi a cd cs1 len)
  (i-i a cd cs1 (%logior #xe00 (ybndswi-imm len)) 5 op-rvy))

;; ---------------------------------------------------------------- Xlm
;; custom-0. car and cdr are offsets 0 and 8 of lref, and set-car and
;; set-cdr the same offsets of sref. lvar is the load of a symbol's value
;; slot that traps on the unbound marker.
(define (i-lref a rd rs1 off)  (i-i a rd rs1 off 0 op-xlm))
(define (i-sref a rs2 rs1 off) (i-s a rs1 rs2 off 1 op-xlm))
(define (i-lvar a rd rs1 off)  (i-i a rd rs1 off 2 op-xlm))

(define (i-car a rd rs1)      (i-lref a rd rs1 0))
(define (i-cdr a rd rs1)      (i-lref a rd rs1 value-bytes))
(define (i-set-car a rs2 rs1) (i-sref a rs2 rs1 0))
(define (i-set-cdr a rs2 rs1) (i-sref a rs2 rs1 value-bytes))

;; The fixnum immediates: the operation in imm[11:10] and a ten-bit signed
;; immediate below it. Every operand is checked to be a fixnum; faddio traps
;; on a result that does not fit in 32 bits, and the trap handler widens the
;; operation into a bignum and resumes.
(define (fixi a op rd rs1 imm)
  (if (if (%>= imm -512) (%< imm 512) nil)
      (i-i a rd rs1 (%logior (%lsh op 10) (%logand imm #x3ff)) 5 op-xlm)
      (error "assembler: a fixnum immediate is ten bits" imm)))
(define (i-faddi a rd rs1 imm)  (fixi a 0 rd rs1 imm))
(define (i-faddio a rd rs1 imm) (fixi a 1 rd rs1 imm))
(define (i-fandi a rd rs1 imm)  (fixi a 2 rd rs1 imm))
(define (i-fori a rd rs1 imm)   (fixi a 3 rd rs1 imm))

;; The R-type group, funct7 choosing.
(define (x-r a f7 rd rs1 rs2) (i-r a f7 rd rs1 rs2 6 op-xlm))

(define (i-fadd a rd rs1 rs2)  (x-r a #x00 rd rs1 rs2))
(define (i-fsub a rd rs1 rs2)  (x-r a #x01 rd rs1 rs2))
(define (i-fmul a rd rs1 rs2)  (x-r a #x02 rd rs1 rs2))
(define (i-fdiv a rd rs1 rs2)  (x-r a #x03 rd rs1 rs2))
(define (i-frem a rd rs1 rs2)  (x-r a #x04 rd rs1 rs2))
(define (i-fand a rd rs1 rs2)  (x-r a #x05 rd rs1 rs2))
(define (i-for a rd rs1 rs2)   (x-r a #x06 rd rs1 rs2))
(define (i-fxor a rd rs1 rs2)  (x-r a #x07 rd rs1 rs2))
(define (i-faddo a rd rs1 rs2) (x-r a #x08 rd rs1 rs2))
(define (i-fsubo a rd rs1 rs2) (x-r a #x09 rd rs1 rs2))
(define (i-fmulo a rd rs1 rs2) (x-r a #x0a rd rs1 rs2))
(define (i-fsll a rd rs1 rs2)  (x-r a #x10 rd rs1 rs2))
(define (i-fsrl a rd rs1 rs2)  (x-r a #x11 rd rs1 rs2))
(define (i-fsra a rd rs1 rs2)  (x-r a #x12 rd rs1 rs2))
;; The comparisons leave the fixnum 0 or 1 in rd.
(define (i-flt a rd rs1 rs2)   (x-r a #x13 rd rs1 rs2))
(define (i-fltu a rd rs1 rs2)  (x-r a #x14 rd rs1 rs2))
(define (i-feq a rd rs1 rs2)   (x-r a #x15 rd rs1 rs2))
;; kind 0 left, 1 right logical, 2 right arithmetic; the amount in rs2.
(define (i-fshi a rd rs1 kind sh) (x-r a (%+ #x18 kind) rd rs1 (%logand sh 31)))

;; Enter the closure in rs1: rs1 is left holding it unsealed, rd the return
;; sentry.
(define (i-jcl a rd rs1)       (x-r a #x20 rd rs1 0))
(define (i-vkind a rd rs1)     (x-r a #x21 rd rs1 0))
;; The length of an object of header type ty, or of any type for 0.
(define (i-lhdr a rd rs1 ty)   (x-r a #x22 rd rs1 ty))
;; Seal a closure object as a closure, for jcl to enter.
(define (i-sealcl a cd cs1)    (x-r a #x23 cd cs1 0))
;; The next pair of the cons run in cs1, or a trap that hands out a new run.
(define (i-npair a cd cs1)     (x-r a #x24 cd cs1 0))
;; An untagged value of kind from-kind (31 for any) given the metadata
;; to-kind, its address kept: char->integer is from 1 to 0.
(define (i-retag a rd rs1 from-kind to-kind)
  (x-r a (%logior #x40 (%logand from-kind 31)) rd rs1 to-kind))

;; Memory by integer address, through DDC: rs1 is the address. A store's
;; rd field and a load's rs2 field say the width, 3 a capability.
(define (ddc-load a sel rd rs1)    (x-r a #x7d rd rs1 sel))
(define (ddc-store a sel rs2 rs1)  (x-r a #x7c sel rs1 rs2))
(define (i-lb-ddc a rd rs1)  (ddc-load a 0 rd rs1))
(define (i-lh-ddc a rd rs1)  (ddc-load a 1 rd rs1))
(define (i-lw-ddc a rd rs1)  (ddc-load a 2 rd rs1))
(define (i-ly-ddc a rd rs1)  (ddc-load a 3 rd rs1))
(define (i-lbu-ddc a rd rs1) (ddc-load a 4 rd rs1))
(define (i-lhu-ddc a rd rs1) (ddc-load a 5 rd rs1))
(define (i-sb-ddc a rs2 rs1) (ddc-store a 0 rs2 rs1))
(define (i-sh-ddc a rs2 rs1) (ddc-store a 1 rs2 rs1))
(define (i-sw-ddc a rs2 rs1) (ddc-store a 2 rs2 rs1))
(define (i-sy-ddc a rs2 rs1) (ddc-store a 3 rs2 rs1))

;; Indexed access: rd, object, index; for the stores rd is the value
;; written. funct7 is the form, store, byte and immediate index, above the
;; type the object has to be, so one instruction checks the tag, the type,
;; the index and the bound.
(define (x-ix a form ty rd obj idx) (i-r a (%logior (%lsh form 4) ty) rd obj idx 7 op-xlm))
(define (i-ldx a rd obj idx ty)  (x-ix a 0 ty rd obj idx))
(define (i-stx a val obj idx ty) (x-ix a 1 ty val obj idx))
(define (i-ldxb a rd obj idx ty)  (x-ix a 2 ty rd obj idx))
(define (i-stxb a val obj idx ty) (x-ix a 3 ty val obj idx))
;; The same four with a constant index of 0..31 in the rs2 field, the way
;; slli keeps its shift amount there.
(define (i-ldxi a rd obj i ty)  (x-ix a 4 ty rd obj i))
(define (i-stxi a val obj i ty) (x-ix a 5 ty val obj i))
(define (i-ldxbi a rd obj i ty)  (x-ix a 6 ty rd obj i))
(define (i-stxbi a val obj i ty) (x-ix a 7 ty val obj i))

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
  (if (if (%> rd 0) (%> rs 0) nil) (i-c-mv a rd rs) (i-ymv a rd rs)))
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
;; needs a scratch register. The ly and sy forms move an 8-byte value, as the
;; low globals that hold one are.
(define (i-lw-abs a rd addr)
  (if (fits12? addr)
      (i-lw a rd $zero addr)
      (begin (i-li a rd addr) (i-lw-ddc a rd rd))))
(define (i-ly-abs a rd addr)
  (if (fits12? addr)
      (i-ly a rd $zero addr)
      (begin (i-li a rd addr) (i-ly-ddc a rd rd))))
(define (i-sw-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sw a rs $zero addr)
      (begin (i-li a scratch addr) (i-sw-ddc a rs scratch))))
(define (i-sy-abs a rs addr scratch)
  (if (fits12? addr)
      (i-sy a rs $zero addr)
      (begin (i-li a scratch addr) (i-sy-ddc a rs scratch))))

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
(define (i-beqx a rs1 rs2 label) (branch a op-xlm 3 rs1 rs2 label))
(define (i-bnex a rs1 rs2 label) (branch a op-xlm 4 rs1 rs2 label))

(define (i-j a label)
  (fixup a 'jal $zero label)
  (enc-j a $zero 0 op-jal))

(define (i-jal a rd label)
  (fixup a 'jal rd label)
  (enc-j a rd 0 op-jal))

;; A capability to a label, derived from PCC by auipc and yaddi. Both halves
;; stay wide: `resolve` rewinds to this offset and writes them again.
(define (i-la a rd label)
  (fixup a 'la rd label)
  (i-auipc a rd 0)
  (i-yaddi-w a rd rd 0))

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
            (i-yaddi-w a rd rd lo-signed)
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
