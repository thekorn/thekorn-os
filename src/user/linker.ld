ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00400000;

    .text : ALIGN(4096) {
        *(.text .text.*)
        . = ALIGN(4096);
    } :text

    .rodata : ALIGN(4096) {
        *(.rodata .rodata.*)
        . = ALIGN(4096);
    } :rodata

    .data : ALIGN(4096) {
        *(.data .data.*)
        . = ALIGN(4096);
    } :data

    .bss (NOLOAD) : ALIGN(4096) {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4096);
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
