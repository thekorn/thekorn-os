.section .text.boot, "ax"
.global _start
.type _start, %function

_start:
    mov x19, x0
    msr DAIFSet, #0xf

    mrs x0, MPIDR_EL1
    and x2, x0, #0xffffff
    ubfx x3, x0, #32, #8
    orr x2, x2, x3
    cbnz x2, .Lpark

    mrs x20, CurrentEL
    lsr x20, x20, #2

    ldr x1, =__bss_start
    ldr x2, =__bss_end
.Lclear_bss:
    cmp x1, x2
    b.hs .Lbss_cleared
    str xzr, [x1], #8
    b .Lclear_bss
.Lbss_cleared:
    ldr x1, =__stack_top
    mov sp, x1

    cmp x20, #3
    b.ne .Lcheck_el2

    // SCR_EL3.NS selects the non-secure world, SCR_EL3.RW selects AArch64
    // for the next lower exception level, and SCR_EL3.HCE enables HVC.
    mov x0, #(1 << 0) | (1 << 8) | (1 << 10)
    msr SCR_EL3, x0
    msr SP_EL2, x1
    adr x0, .Lentered_el2
    msr ELR_EL3, x0
    // EL2h with debug, SError, IRQ, and FIQ exceptions masked.
    mov x0, #0x3c9
    msr SPSR_EL3, x0
    isb
    eret

.Lcheck_el2:
    cmp x20, #2
    b.eq .Lconfigure_el2
    cmp x20, #1
    b.eq .Lentered_el1
    b .Lpark

.Lentered_el2:
.Lconfigure_el2:
    // HCR_EL2.RW selects AArch64 for EL1. EL1h uses SP_EL1.
    mov x0, #(1 << 31)
    msr HCR_EL2, x0
    msr SP_EL1, x1
    adr x0, .Lentered_el1
    msr ELR_EL2, x0
    // EL1h with debug, SError, IRQ, and FIQ exceptions masked.
    mov x0, #0x3c5
    msr SPSR_EL2, x0
    isb
    eret

.Lentered_el1:
    msr SPSel, #1
    mov sp, x1
    ldr x0, =__exception_vectors
    msr VBAR_EL1, x0
    isb

    mov x0, x19
    mov x1, x20
    mrs x2, MPIDR_EL1
    bl kernelMain

.Lpark:
    wfe
    b .Lpark

.size _start, . - _start
