ENTRY(rb3_set_key)
SECTIONS {
    . = 0x82c25000;
    .text : { *(.text.entry_set) *(.text.entry_cbc) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    payload_code_end = .;
    /* Unused writable padding after .XBMOVIE, before .idata. */
    . = 0x82e2c000;
    .bss : { *(.bss*) *(COMMON) }
    payload_end = .;
    /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
