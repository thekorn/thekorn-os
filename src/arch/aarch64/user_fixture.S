.equ SYSCALL_WRITE, 0x100
.equ SYSCALL_YIELD, 0x101
.equ SYSCALL_EXIT, 0x102
.equ SYSCALL_GROW, 0x103

.equ USER_RODATA, 0x00410000
.equ USER_DATA, 0x00420000
.equ USER_HEAP, 0x00430000
.equ UART0, 0x09000000
.equ USER_PROGRESS_TARGET, 10000
.equ USER_TICK_TARGET, 100

.section .user.text, "ax"
.global __user_entry
.type __user_entry, %function
__user_entry:
    movz x0, #0x41, lsl #16
    mov x1, #11
    mov x8, #SYSCALL_WRITE
    svc #0
    cmp x0, #11
    b.ne .Luser_failed

    movz x0, #0x900, lsl #16
    mov x1, #1
    mov x8, #SYSCALL_WRITE
    svc #0
    cmn x0, #2
    b.ne .Luser_failed

    mov x8, #0x200
    svc #0
    cmn x0, #1
    b.ne .Luser_failed

    mov x0, #1
    mov x8, #SYSCALL_GROW
    svc #0
    movz x1, #0x43, lsl #16
    cmp x0, x1
    b.ne .Luser_failed
    str xzr, [x0]

    mov x0, #4
    mov x8, #SYSCALL_GROW
    svc #0
    cmn x0, #3
    b.ne .Luser_failed

    mov x8, #SYSCALL_YIELD
    svc #0

    movz x19, #0x42, lsl #16
    mov x20, #USER_PROGRESS_TARGET
.Luser_progress:
    ldr x0, [x19]
    cmp x0, x20
    b.hs .Luser_wait_for_ticks
    add x0, x0, #1
    str x0, [x19]
.Luser_wait_for_ticks:
    ldr x1, [x19, #8]
    cmp x1, #USER_TICK_TARGET
    b.lo .Luser_progress

    movz x0, #0x900, lsl #16
    ldr w1, [x0]

    ldr x0, =__kernel_start
    ldr x1, [x0]

    movz x0, #0x41, lsl #16
    add x0, x0, #11
    mov x1, #15
    mov x8, #SYSCALL_WRITE
    svc #0
    cmp x0, #15
    b.ne .Luser_failed

    mov x0, #0
    mov x8, #SYSCALL_EXIT
    svc #0

.Luser_failed:
    mov x0, #1
    mov x8, #SYSCALL_EXIT
    svc #0
    b .Luser_failed
.size __user_entry, . - __user_entry

.section .user.rodata, "a"
.ascii "USER:HELLO\n"
.ascii "USER:FAULTS_OK\n"
