; Tina Trap Context Save/Restore — Windows x64 (AMD64)
;
; NOTE: ARM64 Windows would need a separate file with aarch64 instructions
; (stp/ldp for x0-x28, sp, lr, pc). This file targets x64 only.
;
; Calling convention (Windows x64):
;   RCX = first parameter (env pointer)
;   EDX = second parameter (val, for restore only)
;   RAX = return value (i32, for save only)
;
; OS_Trap_Environment layout (80 bytes):
;   0x00: return_address (u64)  — instruction to resume at
;   0x08: stack_pointer  (u64)  — caller's RSP (entry RSP + 8)
;   0x10: rbx            (u64)
;   0x18: rbp            (u64)
;   0x20: rdi            (u64)
;   0x28: rsi            (u64)
;   0x30: r12            (u64)
;   0x38: r13            (u64)
;   0x40: r14            (u64)
;   0x48: r15            (u64)
;   Total: 80 bytes (0x50)

bits 64

global _os_trap_save
global _os_trap_restore

section .text

_os_trap_save:
    ; Save return address
    mov     rax, [rsp]
    mov     [rcx], rax          ; env.return_address
    ; Save the CALLER's stack pointer (RSP after ret pops the return address).
    ; _os_trap_restore jumps directly to the saved return address via jmp,
    ; so RSP must already be at the caller's level — not pointing at a stale
    ; return-address slot that a later call will overwrite.
    lea     rax, [rsp + 8]
    mov     [rcx + 0x08], rax   ; env.stack_pointer (caller's RSP)

    ; Save callee-saved registers
    mov     [rcx + 0x10], rbx
    mov     [rcx + 0x18], rbp
    mov     [rcx + 0x20], rdi
    mov     [rcx + 0x28], rsi
    mov     [rcx + 0x30], r12
    mov     [rcx + 0x38], r13
    mov     [rcx + 0x40], r14
    mov     [rcx + 0x48], r15

    ; Return 0
    xor     eax, eax
    ret

_os_trap_restore:
    ; Restore callee-saved registers
    mov     rbx, [rcx + 0x10]
    mov     rbp, [rcx + 0x18]
    mov     rdi, [rcx + 0x20]
    mov     rsi, [rcx + 0x28]
    mov     r12, [rcx + 0x30]
    mov     r13, [rcx + 0x38]
    mov     r14, [rcx + 0x40]
    mov     r15, [rcx + 0x48]

    ; Restore stack pointer to caller's RSP (saved as RSP+8 during save)
    mov     rsp, [rcx + 0x08]

    ; Set return value and jump to saved return address.
    ; We must NOT use ret here: the original return-address stack slot was
    ; overwritten by the `call _os_trap_restore` instruction that got us here.
    mov     eax, edx
    jmp     qword [rcx]
