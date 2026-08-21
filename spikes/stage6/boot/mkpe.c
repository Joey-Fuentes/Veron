/* mkpe -- wrap a flat, position-independent binary in a PE32+ EFI-application
 * header, from source, with no PE-capable binutils. This is the same trick the
 * Linux kernel uses to make its own EFI stub (arch/x86/boot/tools/build.c): the
 * pinned Veron toolchain's binutils targets ELF only, so we cannot objcopy to
 * PE -- instead we lay the loader out as one contiguous PIC image with its
 * entry at offset 0 (see veron-boot.lds), flatten it with `objcopy -O binary`,
 * and write the PE headers around that blob here.
 *
 * The image is one section, loaded at RVA 0x1000, mapped read/write/execute.
 * It is fully position-independent (RIP-relative), so it needs no base
 * relocations and runs at whatever base the firmware chooses. The section's
 * virtual size exceeds its raw size by the .bss the loader zero-inits at
 * runtime; the firmware zero-fills that tail.
 *
 * usage: mkpe <flat.bin> <bss-bytes> <out.efi>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static void w8(FILE *f, uint8_t v)  { fputc(v, f); }
static void w16(FILE *f, uint16_t v){ w8(f, v & 0xff); w8(f, v >> 8); }
static void w32(FILE *f, uint32_t v){ w16(f, v & 0xffff); w16(f, v >> 16); }
static void w64(FILE *f, uint64_t v){ w32(f, v & 0xffffffff); w32(f, v >> 32); }
static void pad(FILE *f, long to)   { while (ftell(f) < to) w8(f, 0); }

#define SECT_ALIGN 0x1000
#define FILE_ALIGN 0x200
#define IMAGE_BASE 0x0             /* preferred base; PIC runs anywhere */
#define CODE_RVA   0x1000          /* where the one section maps */

static uint32_t align_up(uint32_t v, uint32_t a) { return (v + a - 1) & ~(a - 1); }

int main(int argc, char **argv)
{
    if (argc != 4) { fprintf(stderr, "usage: mkpe <flat.bin> <bss-bytes> <out.efi>\n"); return 2; }
    long bss = strtol(argv[2], 0, 0);

    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror("open input"); return 1; }
    fseek(in, 0, SEEK_END);
    long rawlen = ftell(in);
    fseek(in, 0, SEEK_SET);
    uint8_t *code = malloc(rawlen);
    if (!code || fread(code, 1, rawlen, in) != (size_t)rawlen) { perror("read"); return 1; }
    fclose(in);

    FILE *o = fopen(argv[3], "wb");
    if (!o) { perror("open output"); return 1; }

    uint32_t raw_on_disk   = align_up(rawlen, FILE_ALIGN);
    uint32_t virt_size     = align_up((uint32_t)rawlen + (uint32_t)bss, SECT_ALIGN);
    uint32_t headers_raw   = FILE_ALIGN;               /* headers fit in 0x200 */
    uint32_t size_of_image = CODE_RVA + align_up((uint32_t)rawlen + (uint32_t)bss, SECT_ALIGN);

    /* ---- DOS header + stub ---- */
    w8(o,'M'); w8(o,'Z');
    pad(o, 0x3c);
    w32(o, 0x80);                    /* e_lfanew -> PE header at 0x80 */
    pad(o, 0x80);

    /* ---- PE signature + COFF file header ---- */
    w8(o,'P'); w8(o,'E'); w8(o,0); w8(o,0);
    w16(o, 0x8664);                  /* Machine x86_64 */
    w16(o, 1);                       /* NumberOfSections */
    w32(o, 0);                       /* TimeDateStamp -- 0 for reproducibility */
    w32(o, 0);                       /* PointerToSymbolTable */
    w32(o, 0);                       /* NumberOfSymbols */
    w16(o, 240 - 24);                /* SizeOfOptionalHeader (PE32+ = 240, minus the 24 already counted) */
    w16(o, 0x0206);                  /* Characteristics: EXECUTABLE|LINE_NUMS_STRIPPED|DEBUG_STRIPPED */

    /* ---- optional header (PE32+) ---- */
    w16(o, 0x20b);                   /* Magic PE32+ */
    w8(o, 0); w8(o, 0);              /* linker version */
    w32(o, raw_on_disk);             /* SizeOfCode */
    w32(o, 0);                       /* SizeOfInitializedData */
    w32(o, 0);                       /* SizeOfUninitializedData */
    w32(o, CODE_RVA);                /* AddressOfEntryPoint = section base (efi_main at offset 0) */
    w32(o, CODE_RVA);                /* BaseOfCode */
    w64(o, IMAGE_BASE);              /* ImageBase */
    w32(o, SECT_ALIGN);              /* SectionAlignment */
    w32(o, FILE_ALIGN);              /* FileAlignment */
    w16(o, 0); w16(o, 0);            /* OS version */
    w16(o, 0); w16(o, 0);            /* Image version */
    w16(o, 0); w16(o, 0);            /* Subsystem version */
    w32(o, 0);                       /* Win32VersionValue */
    w32(o, size_of_image);           /* SizeOfImage */
    w32(o, headers_raw);             /* SizeOfHeaders */
    w32(o, 0);                       /* CheckSum */
    w16(o, 10);                      /* Subsystem = EFI application */
    w16(o, 0);                       /* DllCharacteristics */
    w64(o, 0x10000);                 /* SizeOfStackReserve */
    w64(o, 0x10000);                 /* SizeOfStackCommit */
    w64(o, 0x10000);                 /* SizeOfHeapReserve */
    w64(o, 0x10000);                 /* SizeOfHeapCommit */
    w32(o, 0);                       /* LoaderFlags */
    w32(o, 16);                      /* NumberOfRvaAndSizes */
    for (int i = 0; i < 16; i++) { w32(o, 0); w32(o, 0); }  /* all data directories empty */

    /* ---- section header: one section ".text" rwx ---- */
    const char *nm = ".text";
    for (int i = 0; i < 8; i++) w8(o, i < (int)strlen(nm) ? nm[i] : 0);
    w32(o, virt_size);               /* VirtualSize (incl. bss zero-fill) */
    w32(o, CODE_RVA);                /* VirtualAddress */
    w32(o, raw_on_disk);             /* SizeOfRawData */
    w32(o, headers_raw);             /* PointerToRawData */
    w32(o, 0);                       /* PointerToRelocations */
    w32(o, 0);                       /* PointerToLinenumbers */
    w16(o, 0);                       /* NumberOfRelocations */
    w16(o, 0);                       /* NumberOfLinenumbers */
    w32(o, 0xE0000020);              /* CODE|EXECUTE|READ|WRITE */

    /* ---- the code, at PointerToRawData ---- */
    pad(o, headers_raw);
    fwrite(code, 1, rawlen, o);
    pad(o, headers_raw + raw_on_disk);

    fclose(o);
    free(code);
    return 0;
}
