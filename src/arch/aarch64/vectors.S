.section .text.vectors, "ax"
.balign 2048
.global __exception_vectors
.type __exception_vectors, %object

.macro VECTOR_SLOT index
    b .Lvector_\index
    .balign 128
.endm

__exception_vectors:
    VECTOR_SLOT 0
    VECTOR_SLOT 1
    VECTOR_SLOT 2
    VECTOR_SLOT 3
    VECTOR_SLOT 4
    VECTOR_SLOT 5
    VECTOR_SLOT 6
    VECTOR_SLOT 7
    VECTOR_SLOT 8
    VECTOR_SLOT 9
    VECTOR_SLOT 10
    VECTOR_SLOT 11
    VECTOR_SLOT 12
    VECTOR_SLOT 13
    VECTOR_SLOT 14
    VECTOR_SLOT 15
.size __exception_vectors, . - __exception_vectors

.macro VECTOR_HANDLER index
.Lvector_\index:
    sub sp, sp, #288
    stp x0, x1, [sp, #0]
    mov x0, #\index
    b .Lsave_exception
.endm

    VECTOR_HANDLER 0
    VECTOR_HANDLER 1
    VECTOR_HANDLER 2
    VECTOR_HANDLER 3
    VECTOR_HANDLER 4
    VECTOR_HANDLER 5
    VECTOR_HANDLER 6
    VECTOR_HANDLER 7
    VECTOR_HANDLER 8
    VECTOR_HANDLER 9
    VECTOR_HANDLER 10
    VECTOR_HANDLER 11
    VECTOR_HANDLER 12
    VECTOR_HANDLER 13
    VECTOR_HANDLER 14
    VECTOR_HANDLER 15

.Lsave_exception:
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]

    mrs x2, ELR_EL1
    mrs x3, SPSR_EL1
    stp x2, x3, [sp, #248]
    mrs x2, ESR_EL1
    mrs x3, FAR_EL1
    stp x2, x3, [sp, #264]

    mov x1, sp
    bl exceptionHandler

    ldp x2, x3, [sp, #248]
    msr ELR_EL1, x2
    msr SPSR_EL1, x3
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    ldp x0, x1, [sp, #0]
    add sp, sp, #288
    eret
