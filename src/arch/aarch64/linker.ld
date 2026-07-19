ENTRY(_start)

SECTIONS
{
    . = DEFINED(KERNEL_BASE) ? KERNEL_BASE : 0x80000;
    __kernel_start = .;

    .text : ALIGN(4096) {
        __text_start = .;
        KEEP(*(.text.boot))
        . = ALIGN(2048);
        KEEP(*(.text.vectors))
        *(.text .text.*)
        . = ALIGN(4096);
        __text_end = .;
    }

    .rodata : ALIGN(4096) {
        __rodata_start = .;
        *(.rodata .rodata.*)
        . = ALIGN(4096);
        __rodata_end = .;
        __data_start = ABSOLUTE(.);
    }

    .data : ALIGN(4096) {
        *(.got .got.plt)
        *(.data .data.*)
        . = ALIGN(4096);
        __data_end = .;
    }

    .bss (NOLOAD) : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4096);
        __stack_bottom = .;
        . += 64K;
        __stack_top = .;
        . = ALIGN(4096);
        __bss_end = .;
    }

    __kernel_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
    }
}
