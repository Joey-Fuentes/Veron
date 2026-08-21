/* veron-boot.lds -- lay the loader out as one contiguous image the mkpe tool
 * wraps into a single PE section. efi_main is forced first so the PE entry
 * point is a known, fixed offset from the image base. Everything is position-
 * independent (RIP-relative), so the single rwx section runs at any base and
 * needs no relocations. .bss trails the file image; its size is recorded so the
 * PE can declare virtual > raw and the firmware zero-fills it. */
ENTRY(efi_main)
SECTIONS
{
  . = 0;
  .text : {
    *(.text.efi_main)   /* efi_main first -- entry at offset 0 */
    *(.text .text.*)
    *(.rodata .rodata.*)
    *(.data .data.*)
    *(.sdata .sdata.*)
    *(.got .got.*)
    *(.rel.* .rela.*)
  }
  . = ALIGN(16);
  __bss_start = .;
  .bss : { *(.bss .bss.*) *(COMMON) }
  __bss_end = .;
  /DISCARD/ : { *(.dynamic) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
                *(.comment) *(.note.*) *(.eh_frame) *(.interp) }
}
