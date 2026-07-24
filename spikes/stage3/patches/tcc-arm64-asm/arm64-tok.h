#define DEF_ASM_REGS(prefix) \
  DEF(TOK_ASM_##prefix##0, #prefix "0") \
  DEF(TOK_ASM_##prefix##1, #prefix "1") \
  DEF(TOK_ASM_##prefix##2, #prefix "2") \
  DEF(TOK_ASM_##prefix##3, #prefix "3") \
  DEF(TOK_ASM_##prefix##4, #prefix "4") \
  DEF(TOK_ASM_##prefix##5, #prefix "5") \
  DEF(TOK_ASM_##prefix##6, #prefix "6") \
  DEF(TOK_ASM_##prefix##7, #prefix "7") \
  DEF(TOK_ASM_##prefix##8, #prefix "8") \
  DEF(TOK_ASM_##prefix##9, #prefix "9") \
  DEF(TOK_ASM_##prefix##10, #prefix "10") \
  DEF(TOK_ASM_##prefix##11, #prefix "11") \
  DEF(TOK_ASM_##prefix##12, #prefix "12") \
  DEF(TOK_ASM_##prefix##13, #prefix "13") \
  DEF(TOK_ASM_##prefix##14, #prefix "14") \
  DEF(TOK_ASM_##prefix##15, #prefix "15") \
  DEF(TOK_ASM_##prefix##16, #prefix "16") \
  DEF(TOK_ASM_##prefix##17, #prefix "17") \
  DEF(TOK_ASM_##prefix##18, #prefix "18") \
  DEF(TOK_ASM_##prefix##19, #prefix "19") \
  DEF(TOK_ASM_##prefix##20, #prefix "20") \
  DEF(TOK_ASM_##prefix##21, #prefix "21") \
  DEF(TOK_ASM_##prefix##22, #prefix "22") \
  DEF(TOK_ASM_##prefix##23, #prefix "23") \
  DEF(TOK_ASM_##prefix##24, #prefix "24") \
  DEF(TOK_ASM_##prefix##25, #prefix "25") \
  DEF(TOK_ASM_##prefix##26, #prefix "26") \
  DEF(TOK_ASM_##prefix##27, #prefix "27") \
  DEF(TOK_ASM_##prefix##28, #prefix "28") \
  DEF(TOK_ASM_##prefix##29, #prefix "29") \
  DEF(TOK_ASM_##prefix##30, #prefix "30") \
  DEF(TOK_ASM_##prefix##31, #prefix "31")

#define DEF_ASM_VEC_REGS(suffix) \
  DEF(TOK_ASM_v0_##suffix, "v0." #suffix) \
  DEF(TOK_ASM_v1_##suffix, "v1." #suffix) \
  DEF(TOK_ASM_v2_##suffix, "v2." #suffix) \
  DEF(TOK_ASM_v3_##suffix, "v3." #suffix) \
  DEF(TOK_ASM_v4_##suffix, "v4." #suffix) \
  DEF(TOK_ASM_v5_##suffix, "v5." #suffix) \
  DEF(TOK_ASM_v6_##suffix, "v6." #suffix) \
  DEF(TOK_ASM_v7_##suffix, "v7." #suffix) \
  DEF(TOK_ASM_v8_##suffix, "v8." #suffix) \
  DEF(TOK_ASM_v9_##suffix, "v9." #suffix) \
  DEF(TOK_ASM_v10_##suffix, "v10." #suffix) \
  DEF(TOK_ASM_v11_##suffix, "v11." #suffix) \
  DEF(TOK_ASM_v12_##suffix, "v12." #suffix) \
  DEF(TOK_ASM_v13_##suffix, "v13." #suffix) \
  DEF(TOK_ASM_v14_##suffix, "v14." #suffix) \
  DEF(TOK_ASM_v15_##suffix, "v15." #suffix) \
  DEF(TOK_ASM_v16_##suffix, "v16." #suffix) \
  DEF(TOK_ASM_v17_##suffix, "v17." #suffix) \
  DEF(TOK_ASM_v18_##suffix, "v18." #suffix) \
  DEF(TOK_ASM_v19_##suffix, "v19." #suffix) \
  DEF(TOK_ASM_v20_##suffix, "v20." #suffix) \
  DEF(TOK_ASM_v21_##suffix, "v21." #suffix) \
  DEF(TOK_ASM_v22_##suffix, "v22." #suffix) \
  DEF(TOK_ASM_v23_##suffix, "v23." #suffix) \
  DEF(TOK_ASM_v24_##suffix, "v24." #suffix) \
  DEF(TOK_ASM_v25_##suffix, "v25." #suffix) \
  DEF(TOK_ASM_v26_##suffix, "v26." #suffix) \
  DEF(TOK_ASM_v27_##suffix, "v27." #suffix) \
  DEF(TOK_ASM_v28_##suffix, "v28." #suffix) \
  DEF(TOK_ASM_v29_##suffix, "v29." #suffix) \
  DEF(TOK_ASM_v30_##suffix, "v30." #suffix) \
  DEF(TOK_ASM_v31_##suffix, "v31." #suffix)

 DEF_ASM_REGS(x)
 DEF_ASM_REGS(w)
 DEF_ASM_REGS(b)
 DEF_ASM_REGS(h)
 DEF_ASM_REGS(s)
 DEF_ASM_REGS(d)
 DEF_ASM_REGS(q)

/* vector register */
 DEF_ASM_VEC_REGS(B)
 DEF_ASM_VEC_REGS(H)
 DEF_ASM_VEC_REGS(S)
 DEF_ASM_VEC_REGS(D)
 DEF_ASM_VEC_REGS(8B)
 DEF_ASM_VEC_REGS(16B)
 DEF_ASM_VEC_REGS(4H)
 DEF_ASM_VEC_REGS(8H)
 DEF_ASM_VEC_REGS(2S)
 DEF_ASM_VEC_REGS(4S)
 DEF_ASM_VEC_REGS(2D)

/* register aliases and non-general purpose registers */
 DEF_ASM(sp)
 DEF_ASM(wsp)
 DEF_ASM(pc)

 DEF_ASM(fp)
 DEF_ASM(lr)
 DEF_ASM(xzr)
 DEF_ASM(wzr)

/* opcode mnemonics */
/* memory opcodes, order is significant */
 DEF_ASM(ldr)
 DEF_ASM(ldrb)
 DEF_ASM(ldrh)
 DEF_ASM(str)
 DEF_ASM(strb)
 DEF_ASM(strh)
/* other opcodes, order is insignificant */
 DEF_ASM(nop)
 DEF_ASM(svc)
 DEF_ASM(udf)
 DEF_ASM(mov)
 DEF_ASM(ldp)
 DEF_ASM(stp)
 DEF_ASM(add)
 DEF_ASM(adds)
 DEF_ASM(sub)
 DEF_ASM(subs)
 DEF_ASM(cmp)
 DEF_ASM(cmn)
 DEF_ASM(ccmp)
 DEF_ASM(br)
 DEF_ASM(ret)
 DEF_ASM(csinc)
 DEF_ASM(adrp)
 DEF_ASM(orr)
 DEF_ASM(and)
 DEF_ASM(bic)
 DEF_ASM(b)
 DEF_ASM(bl)
 DEF_ASM(blr)
 DEF_ASM(dmb)
 DEF_ASM(mrs)
 DEF_ASM(msr)
 DEF_ASM(ldaxr)
 DEF_ASM(stlxr)
 DEF_ASM(rbit)
 DEF_ASM(clz)
 DEF_ASM(frintp)
 DEF_ASM(fabs)
 DEF_ASM(frintm)
 DEF_ASM(fmadd)
 DEF_ASM(fmaxnm)
 DEF_ASM(fminnm)
 DEF_ASM(frintx)
 DEF_ASM(fcvtzs)
 DEF_ASM(fcvtas)
 DEF_ASM(frinti)
 DEF_ASM(frinta)
 DEF_ASM(fsqrt)
 DEF_ASM(frintz)
 DEF_ASM(tbz)
 DEF_ASM(tbnz)
 DEF_ASM(cbz)
 DEF_ASM(cbnz)
 DEF_ASM(dup)
 DEF_ASM(dc)

/* opcodes, but also shift modes; order is significant */
 DEF_ASM(lsl)
 DEF_ASM(lsr)
 DEF_ASM(asr)
 DEF_ASM(ror)

/* opcodes, but also extend modes; order is significant */
 DEF_ASM(uxtb)
 DEF_ASM(uxth)
 DEF_ASM(uxtw)
 DEF_ASM(uxtx)
 DEF_ASM(sxtb)
 DEF_ASM(sxth)
 DEF_ASM(sxtw)
 DEF_ASM(sxtx)

/* conditions for conditional instructions; order is significant */
 DEF_ASM(eq)
 DEF_ASM(ne)
 DEF_ASM(cs)
 DEF_ASM(cc)
 DEF_ASM(mi)
 DEF_ASM(pl)
 DEF_ASM(vs)
 DEF_ASM(vc)
 DEF_ASM(hi)
 DEF_ASM(ls)
 DEF_ASM(ge)
 DEF_ASM(lt)
 DEF_ASM(gt)
 DEF_ASM(le)
 DEF_ASM(al)
 DEF_ASM(nv)
/* condition code aliases; order still significant */
 DEF_ASM(hs)
 DEF_ASM(lo)

/* conditional jumps; order is significant */
 DEF(TOK_ASM_b_eq, "b.eq")
 DEF(TOK_ASM_b_ne, "b.ne")
 DEF(TOK_ASM_b_cs, "b.cs")
 DEF(TOK_ASM_b_cc, "b.cc")
 DEF(TOK_ASM_b_mi, "b.mi")
 DEF(TOK_ASM_b_pl, "b.pl")
 DEF(TOK_ASM_b_vs, "b.vs")
 DEF(TOK_ASM_b_vc, "b.vc")
 DEF(TOK_ASM_b_hi, "b.hi")
 DEF(TOK_ASM_b_ls, "b.ls")
 DEF(TOK_ASM_b_ge, "b.ge")
 DEF(TOK_ASM_b_lt, "b.lt")
 DEF(TOK_ASM_b_gt, "b.gt")
 DEF(TOK_ASM_b_le, "b.le")
 DEF(TOK_ASM_b_al, "b.al")
 DEF(TOK_ASM_b_nv, "b.nv")
/* conditional jump aliases; order still significant */
 DEF(TOK_ASM_b_hs, "b.hs")
 DEF(TOK_ASM_b_lo, "b.lo")

/* reloc strings */
 DEF_ASM(lo12)

/* dmb operands */
 DEF_ASM(oshld)
 DEF_ASM(oshst)
 DEF_ASM(osh)
 DEF_ASM(nshld)
 DEF_ASM(nshst)
 DEF_ASM(nsh)
 DEF_ASM(ishld)
 DEF_ASM(ishst)
 DEF_ASM(ish)
 DEF_ASM(ld)
 DEF_ASM(st)
 DEF_ASM(sy)

/* system registers */
 DEF_ASM(fpsr)
 DEF_ASM(fpcr)
 DEF_ASM(tpidr_el0)
 DEF_ASM(dczid_el0)

/* DC operations */
 DEF_ASM(zva)

/* We don't actually have push and pop mnemonics.
 * But tccpp assumes ASM_TOK_push and ASM_TOK_pop
 * exist. So we make them available, for #pragma use. */
 DEF_ASM(push)
 DEF_ASM(pop)
