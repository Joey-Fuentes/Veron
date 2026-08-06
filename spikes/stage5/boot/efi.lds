OUTPUT_FORMAT("elf64-littleaarch64")
ENTRY(efi_main)
SECTIONS {
  . = 0;
  ImageBase = .;
  .text : { *(.text*) *(.rodata*) } :text
  . = ALIGN(4096);
  .data : { *(.data*) *(.sdata*) *(.got*) *(.bss*) *(COMMON) } :data
  . = ALIGN(4096);
  .rela : { *(.rela*) } :data
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) }
}
PHDRS { text PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
