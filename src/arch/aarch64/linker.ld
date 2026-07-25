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

    .user_text : ALIGN(4096) {
        __user_text_start = .;
        KEEP(*(.user.text))
        . = ALIGN(4096);
        __user_text_end = .;
    }

    .user_rodata : ALIGN(4096) {
        __user_rodata_start = .;
        KEEP(*(.user.rodata))
        . = ALIGN(4096);
        __user_rodata_end = .;
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

    .user_bss (NOLOAD) : ALIGN(4096) {
        __bss_start = .;
        __user_bss_start = .;
        *(.user.bss)
        . = ALIGN(4096);
        __user_bss_end = .;
    }

    .bss (NOLOAD) : ALIGN(4096) {
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
