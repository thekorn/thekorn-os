.section .text.boot, "ax"
.global _start
.type _start, %function

_start:
    mov x19, x0

    ldr x1, =__bss_start
    ldr x2, =__bss_end
1:
    cmp x1, x2
    b.hs 2f
    str xzr, [x1], #8
    b 1b
2:
    ldr x1, =__stack_top
    mov sp, x1
    mov x0, x19
    bl kernelMain

3:
    wfe
    b 3b

.size _start, . - _start
