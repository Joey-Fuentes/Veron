"""Reference model of stage 2 (mini-c) SEED capability: `return N`.
Reads a C-ish source, finds `return`, and emits assembly that exits with N:
    mov x0 <N>
    mov x8 93
    svc
Everything else in the source is ignored for this first slice. N's digits are
copied straight from the source (no number<->string conversion needed).
"""
def stage2(src):
    i = src.find("return")
    if i < 0:
        digits = "0"
    else:
        j = i + 6
        while j < len(src) and src[j] in " \t":
            j += 1
        d = ""
        while j < len(src) and src[j].isdigit():
            d += src[j]; j += 1
        digits = d if d else "0"
    return "mov x0 " + digits + "\nmov x8 93\nsvc\n"
