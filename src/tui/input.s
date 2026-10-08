.include "opcode.inc"
# opcode tui: incremental terminal input parser.
#
#   input_init(in)               zero the caller-allocated parser state
#   input_free(in)               release owned paste buffers (init calls it)
#   input_feed(in, ptr, len)     consume raw bytes (arbitrary split boundaries)
#   input_next(in, InputEvent*)  pop one event -> 1, or 0 when the queue is empty
#   input_idle(in, now_ms)       arm/fire the 50 ms partial-sequence timeout
#   input_in_size                sizeof(struct input) for the caller's zeroed struct
#
#   InputEvent { u32 key; u32 cp; u32 mods; u32 pad;
#                u64 paste; u64 paste_len; }   mods: bit0 alt, bit1 shift, bit2 ctrl
#   paste/paste_len are only meaningful for K_PASTE; other keys leave them 0.
#
# Escape sequences follow this parser:
#
#   * CSI A/B/C/D/H/F movement, CSI Z shift-Tab, CSI ~ keys (Home/Insert/Delete/
#     End/PgUp/PgDn/F1-F4), CSI u kitty keyboard protocol (cp;mods;event), SS3
#     movement and F1-F4, plus the legacy single-parameter modifier form
#     (CSI 5D = Ctrl+Left, CSI 3A = Alt+Up; n-1 encodes xterm modifiers).
#   * A CR immediately followed by LF is one Enter; a bare LF is Enter too.
#   * UTF-8 is validated strictly: bad leads and invalid continuations report
#     U+FFFD, and an overlong/surrogate/>U+10FFFF sequence reports one U+FFFD
#     per byte it consumed (matching src/base/uni.s:utf8_decode's one-byte rule).
#
# A lone ESC (and an incomplete CSI/SS3 sequence) is held, not flushed by
# input_next: the shell's poll loop calls input_idle(in, now_ms) each tick and
# the 50 ms timeout then emits K_ESC or drops the incomplete sequence.  This is
# also the Alt disambiguation rule, and it keeps a real escape sequence that
# arrives in a later read from being split into K_ESC + a literal byte.
#
# Layout (u32 unless noted):
#   ring[64] 2048  event queue, 64 * 32 bytes
#   head       4  ring read index
#   count      4  queued events
#   state      4  IN_GROUND / IN_ESC / IN_CSI / IN_SS3 / IN_PASTE / IN_STR
#   np         4  committed CSI parameters
#   alt        4  alt modifier pending on an in-flight UTF-8 sequence
#   num        4  CSI current numeric parameter
#   hasnum     4  CSI saw digits for the current parameter
#   utf        4  UTF-8 continuation bytes collected so far
#   ucp        4  UTF-8 codepoint accumulator
#   uneed      4  UTF-8 total bytes for the current sequence
#   pmatch     4  bracketed-paste terminator bytes matched
#   stresc     4  ESC seen inside an OSC/DCS/APC payload
#   last_cr    4  last ground byte was CR (collapse a following LF)
#   par[8]    32  CSI parameters
#   pbuf      24  bracketed-paste accumulator (SB: ptr/len/cap)
#   esc_armed  4  1 once the idle timer has been armed for the current state
#   pad        4  keep esc_ms/paste_prev 8-aligned
#   esc_ms     8  monotonic ms when the idle timer was armed
#   paste_prev 8  owned payload of the last popped K_PASTE
#
# Bracketed paste accumulates the raw bytes verbatim in IN_pbuf (no UTF-8
# decoding, no U+FFFD substitution) and emits exactly one K_PASTE event when
# the \x1b[201~ terminator is seen; the buffer is not freed until the next
# paste starts so the event's pointer stays valid for the consumer.  OSC/DCS/APC
# strings (\x1b], \x1bP, \x1b_) are swallowed up to BEL or ST so their payload
# never leaks as keystrokes.
#
# The queue holds 64 events; overflow drops new events.

.equ K_UP,        0x110001
.equ K_DOWN,      0x110002
.equ K_LEFT,      0x110003
.equ K_RIGHT,     0x110004
.equ K_HOME,      0x110005
.equ K_END,       0x110006
.equ K_PGUP,      0x110007
.equ K_PGDN,      0x110008
.equ K_DEL,       0x110009
.equ K_INSERT,    0x11000a
.equ K_F1,        0x11000b
.equ K_F2,        0x11000c
.equ K_F3,        0x11000d
.equ K_F4,        0x11000e
.equ K_BACKSPACE, 0x7f
.equ K_ENTER,     0x0a
.equ K_TAB,       0x09
.equ K_ESC,       0x1b
.equ K_PASTE,     0x110010

.equ IN_MAXEV,   64
.equ IN_EVSZ,    32
.equ IN_RINGSZ,  IN_MAXEV * IN_EVSZ
.equ IN_MASK,    IN_MAXEV - 1

.equ IN_GROUND,  0
.equ IN_ESC,     1
.equ IN_CSI,     2
.equ IN_SS3,     3
.equ IN_PASTE,   4
.equ IN_STR,     5              # OSC/DCS/APC payload

.equ IN_ESC_TIMEOUT_MS, 50      # idle timeout for a lone ESC / partial CSI/SS3

STRUCT
F IN_ring,   IN_RINGSZ
F IN_head,   4
F IN_count,  4
F IN_state,  4
F IN_np,     4
F IN_alt,    4
F IN_num,    4
F IN_hasnum, 4
F IN_utf,    4
F IN_ucp,    4
F IN_uneed,  4
F IN_pmatch, 4
F IN_stresc, 4                  # saw ESC inside an OSC/DCS/APC payload
F IN_last_cr, 4                 # last ground byte was CR
F IN_par,    32
F IN_pbuf,       SB_SIZE        # bracketed-paste accumulator (8-aligned)
F IN_esc_armed, 4               # 1 once the idle timer is armed
F IN_pad,        4              # keep IN_esc_ms 8-aligned
F IN_esc_ms,     8             # monotonic ms the idle timer was armed at
F IN_paste_prev, 8             # owned payload of the last popped K_PASTE
ENDSTRUCT IN_SIZE

.data
.p2align 3
.globl input_in_size
GTYPE input_in_size, @object
input_in_size: .quad IN_SIZE
.globl input_ev_size
GTYPE input_ev_size, @object
input_ev_size: .quad IN_EVSZ

.section .rodata
.Lterm:
    .byte 0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e      # "\x1b[201~"

.text

# ---------------------------------------------------------------- queue
# .Lemit(rdi=in, esi=key, edx=cp, ecx=mods) - drop when full.  Leaf.
.Lemit:
    mov eax, [rdi + IN_count]
    cmp eax, IN_MAXEV
    jae .Lemit_done
    lea r8, [rdi + IN_ring]
    mov r9d, [rdi + IN_head]
    add r9d, eax
    and r9d, IN_MASK
    shl r9, 5                    # index * 32
    add r8, r9
    mov [r8], esi
    mov [r8 + 4], edx
    mov [r8 + 8], ecx
    mov dword ptr [r8 + 12], 0   # pad
    mov qword ptr [r8 + 16], 0   # paste
    mov qword ptr [r8 + 24], 0   # paste_len
    inc eax
    mov [rdi + IN_count], eax
.Lemit_done:
    ret

# .Lemit_paste(rdi=in) - enqueue one K_PASTE, handing IN_pbuf's buffer to the
# event and leaving IN_pbuf empty so a second paste in the same feed allocates
# a fresh buffer (no aliasing between queued events).  Drop when full, keeping
# the buffer in IN_pbuf.
.Lemit_paste:
    mov eax, [rdi + IN_count]
    cmp eax, IN_MAXEV
    jae .Lep_done
    lea r8, [rdi + IN_ring]
    mov r9d, [rdi + IN_head]
    add r9d, eax
    and r9d, IN_MASK
    shl r9, 5                    # index * 32
    add r8, r9
    mov dword ptr [r8], K_PASTE
    mov dword ptr [r8 + 4], 0
    mov dword ptr [r8 + 8], 0
    mov dword ptr [r8 + 12], 0
    mov r10, [rdi + IN_pbuf + SB_ptr]
    mov [r8 + 16], r10
    mov r10, [rdi + IN_pbuf + SB_len]
    mov [r8 + 24], r10
    # detach the payload: ownership moves to the queued event
    mov qword ptr [rdi + IN_pbuf + SB_ptr], 0
    mov qword ptr [rdi + IN_pbuf + SB_len], 0
    mov qword ptr [rdi + IN_pbuf + SB_cap], 0
    inc eax
    mov [rdi + IN_count], eax
.Lep_done:
    ret

# .Lemit_fffd_n(rdi=in, esi=count, edx=mods) - emit `count` K_CHAR U+FFFD
# events.  Used when a malformed UTF-8 sequence is consumed; the strict
# decoder reports one replacement per byte it advanced over.
.Lemit_fffd_n:
    push rbx
    push r12
    push r13
    mov ebx, esi
    mov r12d, edx
    mov r13, rdi
.Lffn_loop:
    mov rdi, r13
    mov esi, 0xfffd
    mov edx, 0xfffd
    mov ecx, r12d
    call .Lemit
    dec ebx
    jnz .Lffn_loop
    pop r13
    pop r12
    pop rbx
    ret

# .Ldecode(ecx=param) -> eax: xterm modifier parameter -> opcode mods.  Leaf.
.Ldecode:
    xor eax, eax
    cmp ecx, 2
    jb 1f
    dec ecx
    test ecx, 1
    jz 2f
    or eax, 2                    # shift
2:  test ecx, 2
    jz 3f
    or eax, 1                    # alt
3:  test ecx, 4
    jz 1f
    or eax, 4                    # ctrl
1:  ret

# .Lmods(rdi=in) -> eax: xterm modifier parameter (par[1]) decoded.  Leaf.
.Lmods:
    mov ecx, [rdi + IN_np]
    cmp ecx, 2
    jb 1f
    mov ecx, [rdi + IN_par + 4]
    jmp .Ldecode
1:  xor eax, eax
    ret

# .Lmods_legacy(rdi=in) -> eax: par[1] when present, else the legacy
# single-parameter form (CSI 5D = Ctrl+Left).  Leaf.
.Lmods_legacy:
    mov ecx, [rdi + IN_np]
    cmp ecx, 2
    jae 2f
    cmp ecx, 1
    jne 1f
    mov ecx, [rdi + IN_par]
    cmp ecx, 2
    jb 1f
    cmp ecx, 8
    ja 1f
    jmp .Ldecode
2:  mov ecx, [rdi + IN_par + 4]
    jmp .Ldecode
1:  xor eax, eax
    ret

# ---------------------------------------------------------------- helpers
# .Lground(rdi=in, esi=byte) -> eax (ignored except when it tail-jumps)
.Lground:
    cmp esi, 0x80
    jae .Lg_utf
    # an ASCII byte cancels an in-flight UTF-8 sequence: report one U+FFFD per
    # buffered byte, then dispatch the byte normally
    cmp dword ptr [rdi + IN_utf], 0
    je .Lg_lastcr
    mov ebx, esi
    mov r8d, [rdi + IN_alt]      # keep the pending sequence's alt modifier
    mov r9d, [rdi + IN_utf]      # bytes consumed so far
    mov dword ptr [rdi + IN_utf], 0
    mov dword ptr [rdi + IN_uneed], 0
    mov dword ptr [rdi + IN_alt], 0
    mov esi, r9d
    mov edx, r8d
    sub rsp, 8
    call .Lemit_fffd_n
    add rsp, 8
    mov esi, ebx
.Lg_lastcr:
    # CRLF collapse: a CR already emitted Enter, so swallow a following LF
    cmp dword ptr [rdi + IN_last_cr], 0
    je .Lg_dispatch
    mov dword ptr [rdi + IN_last_cr], 0
    cmp esi, 0x0a
    je .Lg_consume
.Lg_dispatch:
    cmp esi, 0x1b
    je .Lg_esc
    cmp esi, 0x0d
    je .Lg_cr
    cmp esi, 0x0a
    je .Lg_enter
    cmp esi, 0x09
    je .Lg_tab
    cmp esi, 0x7f
    je .Lg_bs
    cmp esi, 0x08
    je .Lg_bs
    cmp esi, 0x20
    jb .Lg_ctrl
    mov edx, esi                 # printable: key == cp
    xor ecx, ecx
    sub rsp, 8
    call .Lemit
    add rsp, 8
    mov eax, 1
    ret
.Lg_cr:
    mov dword ptr [rdi + IN_last_cr], 1
    jmp .Lg_enter
.Lg_consume:
    mov eax, 1
    ret
.Lg_ctrl:
    mov edx, esi                 # ctrl+byte: key = cp = byte, mods ctrl
    mov ecx, 4
    sub rsp, 8
    call .Lemit
    add rsp, 8
    mov eax, 1
    ret
.Lg_enter:
    mov esi, K_ENTER
    jmp .Lg_low
.Lg_tab:
    mov esi, K_TAB
    jmp .Lg_low
.Lg_bs:
    mov esi, K_BACKSPACE
.Lg_low:
    mov edx, esi
    xor ecx, ecx
    sub rsp, 8
    call .Lemit
    add rsp, 8
    mov eax, 1
    ret
.Lg_esc:
    mov dword ptr [rdi + IN_state], IN_ESC
    mov dword ptr [rdi + IN_esc_armed], 0
    mov eax, 1
    ret
.Lg_utf:
    mov dword ptr [rdi + IN_last_cr], 0
    xor edx, edx
    jmp .Lutf8

# .Lutf8(rdi=in, esi=byte, edx=mods) -> eax: 1 consumed, 0 retry byte as ground.
.Lutf8:
    mov r8d, esi
    mov eax, [rdi + IN_utf]
    test eax, eax
    jnz .Lu_cont
    mov dword ptr [rdi + IN_alt], edx
    mov ecx, r8d
    cmp ecx, 0xc2
    jb .Lu_badlead
    cmp ecx, 0xe0
    jb .Lu_need2
    cmp ecx, 0xf0
    jb .Lu_need3
    cmp ecx, 0xf5
    jae .Lu_badlead
    and ecx, 0x07
    mov [rdi + IN_ucp], ecx
    mov dword ptr [rdi + IN_uneed], 4
    mov dword ptr [rdi + IN_utf], 1
    mov eax, 1
    ret
.Lu_need2:
    and ecx, 0x1f
    mov [rdi + IN_ucp], ecx
    mov dword ptr [rdi + IN_uneed], 2
    mov dword ptr [rdi + IN_utf], 1
    mov eax, 1
    ret
.Lu_need3:
    and ecx, 0x0f
    mov [rdi + IN_ucp], ecx
    mov dword ptr [rdi + IN_uneed], 3
    mov dword ptr [rdi + IN_utf], 1
    mov eax, 1
    ret
.Lu_cont:
    mov ecx, r8d
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lu_badcont
    mov eax, [rdi + IN_ucp]
    mov ecx, [rdi + IN_utf]
    shl eax, 6
    and r8d, 0x3f
    or eax, r8d
    mov [rdi + IN_ucp], eax
    inc ecx
    mov [rdi + IN_utf], ecx
    cmp ecx, [rdi + IN_uneed]
    jb .Lu_one
    # complete: validate against the strict decoder's minimum, surrogates and
    # the U+10FFFF ceiling before emitting
    mov r9d, [rdi + IN_alt]      # mods
    mov r10d, [rdi + IN_uneed]   # byte count
    mov dword ptr [rdi + IN_alt], 0
    mov dword ptr [rdi + IN_utf], 0
    mov dword ptr [rdi + IN_uneed], 0
    mov r11d, eax                # cp
    cmp r10d, 4
    je .Lu_v4
    cmp r10d, 3
    je .Lu_v3
    cmp eax, 0x80                # 2-byte overlong
    jb .Lu_rep
    jmp .Lu_ok
.Lu_v3:
    cmp eax, 0x800               # 3-byte overlong
    jb .Lu_rep
    cmp eax, 0xD800              # surrogate half
    jb .Lu_ok
    cmp eax, 0xDFFF
    jbe .Lu_rep
    jmp .Lu_ok
.Lu_v4:
    cmp eax, 0x10000             # 4-byte overlong
    jb .Lu_rep
    cmp eax, 0x10FFFF            # out of range
    ja .Lu_rep
.Lu_ok:
    mov esi, r11d
    mov edx, r11d
    mov ecx, r9d
    sub rsp, 8
    call .Lemit
    add rsp, 8
    jmp .Lu_one
.Lu_rep:
    mov esi, r10d
    mov edx, r9d
    sub rsp, 8
    call .Lemit_fffd_n
    add rsp, 8
    jmp .Lu_one
.Lu_badlead:
    mov r9d, [rdi + IN_alt]
    mov dword ptr [rdi + IN_alt], 0
    mov dword ptr [rdi + IN_utf], 0
    mov dword ptr [rdi + IN_uneed], 0
    mov esi, 1
    mov edx, r9d
    sub rsp, 8
    call .Lemit_fffd_n
    add rsp, 8
    mov eax, 1
    ret
.Lu_badcont:
    mov r8d, [rdi + IN_alt]      # mods
    mov r9d, [rdi + IN_utf]      # bytes consumed for the discarded sequence
    mov dword ptr [rdi + IN_alt], 0
    mov dword ptr [rdi + IN_utf], 0
    mov dword ptr [rdi + IN_uneed], 0
    mov esi, r9d
    mov edx, r8d
    sub rsp, 8
    call .Lemit_fffd_n
    add rsp, 8
    xor eax, eax                 # caller reprocesses the offending byte
    ret
.Lu_one:
    mov eax, 1
    ret

# .Lcsi(rdi=in, esi=byte) : accumulates params, dispatches finals.  Consumes.
.Lcsi:
    mov ecx, esi
    lea eax, [rcx - 0x30]
    cmp eax, 9
    ja .Lc_nd
    mov eax, [rdi + IN_num]
    imul eax, eax, 10
    add eax, ecx
    sub eax, 0x30
    mov [rdi + IN_num], eax
    mov dword ptr [rdi + IN_hasnum], 1
    mov eax, 1
    ret
.Lc_nd:
    cmp ecx, 0x3b                # ';'
    je .Lc_sep
    cmp ecx, 0x3a                # ':' sub-parameter separator
    je .Lc_sep
    cmp ecx, 0x40
    jb .Lc_ignore
    cmp ecx, 0x7e
    ja .Lc_ignore
    # ---- final byte: commit the pending parameter
    cmp dword ptr [rdi + IN_hasnum], 0
    je .Lc_nocommit
    mov eax, [rdi + IN_np]
    cmp eax, 8
    jae .Lc_nocommit
    mov r8d, [rdi + IN_num]
    mov [rdi + IN_par + rax*4], r8d
    inc eax
    mov [rdi + IN_np], eax
.Lc_nocommit:
    mov dword ptr [rdi + IN_hasnum], 0
    mov dword ptr [rdi + IN_num], 0
    cmp ecx, 0x7e                # '~'
    je .Lc_tilde
    cmp ecx, 0x75                # 'u' kitty keyboard protocol
    je .Lc_kitty
    cmp ecx, 0x5a                # 'Z'
    je .Lc_ztab
    cmp ecx, 0x41                # 'A'
    je .Lc_up
    cmp ecx, 0x42
    je .Lc_down
    cmp ecx, 0x43
    je .Lc_right
    cmp ecx, 0x44
    je .Lc_left
    cmp ecx, 0x48                # 'H'
    je .Lc_home
    cmp ecx, 0x46                # 'F'
    je .Lc_end
    jmp .Lc_finish
.Lc_sep:
    mov eax, [rdi + IN_np]
    cmp eax, 8
    jae .Lc_sep_done
    mov r8d, [rdi + IN_num]
    mov [rdi + IN_par + rax*4], r8d
    inc eax
    mov [rdi + IN_np], eax
.Lc_sep_done:
    mov dword ptr [rdi + IN_hasnum], 0
    mov dword ptr [rdi + IN_num], 0
    mov eax, 1
    ret
.Lc_ignore:
    mov eax, 1
    ret
.Lc_up:
    mov ecx, K_UP
    jmp .Lc_move
.Lc_down:
    mov ecx, K_DOWN
    jmp .Lc_move
.Lc_left:
    mov ecx, K_LEFT
    jmp .Lc_move
.Lc_right:
    mov ecx, K_RIGHT
    jmp .Lc_move
.Lc_home:
    mov ecx, K_HOME
    jmp .Lc_move
.Lc_end:
    mov ecx, K_END
.Lc_move:
    # A/B/C/D/H/F accept both the standard `1;mod` form and the legacy
    # single-parameter form (CSI 5D = Ctrl+Left).
    sub rsp, 24
    mov [rsp], ecx
    call .Lmods_legacy
    mov ecx, eax
    mov esi, [rsp]
    xor edx, edx                 # cp = 0 for special keys
    call .Lemit
    add rsp, 24
    jmp .Lc_finish
.Lc_ztab:
    sub rsp, 24
    mov dword ptr [rsp], K_TAB
    call .Lmods
    or eax, 2                    # shift+tab
    mov ecx, eax
    mov esi, [rsp]
    mov edx, esi
    call .Lemit
    add rsp, 24
    jmp .Lc_finish
.Lc_tilde:
    mov eax, [rdi + IN_np]
    test eax, eax
    jz .Lc_finish
    mov eax, [rdi + IN_par]
    cmp eax, 200
    je .Lc_paste
    cmp eax, 1
    je .Lct_home
    cmp eax, 7
    je .Lct_home
    cmp eax, 2
    je .Lct_ins
    cmp eax, 3
    je .Lct_del
    cmp eax, 4
    je .Lct_end
    cmp eax, 8
    je .Lct_end
    cmp eax, 5
    je .Lct_pgup
    cmp eax, 6
    je .Lct_pgdn
    cmp eax, 11
    je .Lct_f1
    cmp eax, 12
    je .Lct_f2
    cmp eax, 13
    je .Lct_f3
    cmp eax, 14
    je .Lct_f4
    jmp .Lc_finish
.Lct_home:
    mov ecx, K_HOME
    jmp .Lct_emit
.Lct_ins:
    mov ecx, K_INSERT
    jmp .Lct_emit
.Lct_del:
    mov ecx, K_DEL
    jmp .Lct_emit
.Lct_end:
    mov ecx, K_END
    jmp .Lct_emit
.Lct_pgup:
    mov ecx, K_PGUP
    jmp .Lct_emit
.Lct_pgdn:
    mov ecx, K_PGDN
    jmp .Lct_emit
.Lct_f1:
    mov ecx, K_F1
    jmp .Lct_emit
.Lct_f2:
    mov ecx, K_F2
    jmp .Lct_emit
.Lct_f3:
    mov ecx, K_F3
    jmp .Lct_emit
.Lct_f4:
    mov ecx, K_F4
.Lct_emit:
    # `~` keys never use the legacy single-parameter modifier form: par[0] is
    # the key code, so only par[1] carries modifiers.
    sub rsp, 24
    mov [rsp], ecx
    call .Lmods
    mov ecx, eax
    mov esi, [rsp]
    xor edx, edx
    call .Lemit
    add rsp, 24
    jmp .Lc_finish
.Lc_kitty:
    # kitty keyboard protocol: par[0]=codepoint, par[1]=modifier param
    sub rsp, 24
    mov eax, [rdi + IN_np]
    test eax, eax
    jz .Lck_done
    mov r8d, [rdi + IN_par]
    mov [rsp], r8d
    call .Lmods
    mov [rsp + 4], eax
    mov r8d, [rsp]
    cmp r8d, 8
    je .Lck_back
    cmp r8d, 127
    je .Lck_back
    cmp r8d, 13
    je .Lck_enter
    cmp r8d, 9
    je .Lck_tab
    cmp r8d, 27
    je .Lck_esc
    test r8d, r8d
    jz .Lck_done
    mov esi, r8d                 # printable: key == cp == codepoint
    mov edx, r8d
    mov ecx, [rsp + 4]
    call .Lemit
    jmp .Lck_done
.Lck_back:
    mov esi, K_BACKSPACE
    jmp .Lck_special
.Lck_enter:
    mov esi, K_ENTER
    jmp .Lck_special
.Lck_tab:
    mov esi, K_TAB
    jmp .Lck_special
.Lck_esc:
    mov esi, K_ESC
.Lck_special:
    xor edx, edx                 # cp = 0 for special keys
    mov ecx, [rsp + 4]
    call .Lemit
.Lck_done:
    add rsp, 24
    jmp .Lc_finish
.Lc_paste:
    mov r10, rdi
    lea rdi, [rdi + IN_pbuf]
    sub rsp, 8
    call sb_clear                 # start a fresh paste accumulator
    add rsp, 8
    mov rdi, r10
    mov dword ptr [rdi + IN_state], IN_PASTE
    mov dword ptr [rdi + IN_pmatch], 0
    mov eax, 1
    ret
.Lc_finish:
    mov dword ptr [rdi + IN_state], IN_GROUND
    mov eax, 1
    ret

# .Lss3(rdi=in, esi=byte) : \x1bO + one final.  Consumes; unknown finals swallowed.
.Lss3:
    mov ecx, esi
    cmp ecx, 0x40
    jb .Ls_ret
    cmp ecx, 0x7e
    ja .Ls_ret
    cmp ecx, 0x41
    je .Ls_up
    cmp ecx, 0x42
    je .Ls_down
    cmp ecx, 0x43
    je .Ls_right
    cmp ecx, 0x44
    je .Ls_left
    cmp ecx, 0x48
    je .Ls_home
    cmp ecx, 0x46
    je .Ls_end
    cmp ecx, 0x50                # 'P'
    je .Ls_f1
    cmp ecx, 0x51                # 'Q'
    je .Ls_f2
    cmp ecx, 0x52                # 'R'
    je .Ls_f3
    cmp ecx, 0x53                # 'S'
    je .Ls_f4
    jmp .Ls_finish
.Ls_up:
    mov ecx, K_UP
    jmp .Ls_emit
.Ls_down:
    mov ecx, K_DOWN
    jmp .Ls_emit
.Ls_left:
    mov ecx, K_LEFT
    jmp .Ls_emit
.Ls_right:
    mov ecx, K_RIGHT
    jmp .Ls_emit
.Ls_home:
    mov ecx, K_HOME
    jmp .Ls_emit
.Ls_end:
    mov ecx, K_END
    jmp .Ls_emit
.Ls_f1:
    mov ecx, K_F1
    jmp .Ls_emit
.Ls_f2:
    mov ecx, K_F2
    jmp .Ls_emit
.Ls_f3:
    mov ecx, K_F3
    jmp .Ls_emit
.Ls_f4:
    mov ecx, K_F4
.Ls_emit:
    sub rsp, 24
    mov [rsp], ecx
    mov esi, [rsp]
    xor edx, edx
    xor ecx, ecx
    call .Lemit
    add rsp, 24
    jmp .Ls_finish
.Ls_finish:
    mov dword ptr [rdi + IN_state], IN_GROUND
.Ls_ret:
    mov eax, 1
    ret

# .Lstr(rdi=in, esi=byte) : consume an OSC/DCS/APC payload until BEL or ST.
# Nothing from the payload is ever emitted as a keystroke.
.Lstr:
    cmp dword ptr [rdi + IN_stresc], 0
    jne .Lstr_afteresc
    cmp esi, 0x07                # BEL terminates OSC
    je .Lstr_end
    cmp esi, 0x1b                # ESC may begin ST
    je .Lstr_esc
    mov eax, 1
    ret
.Lstr_esc:
    mov dword ptr [rdi + IN_stresc], 1
    mov eax, 1
    ret
.Lstr_afteresc:
    mov dword ptr [rdi + IN_stresc], 0
    cmp esi, 0x5c                # '\\' completes ST
    je .Lstr_end
    cmp esi, 0x07
    je .Lstr_end
    cmp esi, 0x1b
    je .Lstr_esc
    mov eax, 1
    ret
.Lstr_end:
    mov dword ptr [rdi + IN_state], IN_GROUND
    mov eax, 1
    ret

# .Lpaste(rdi=in, esi=byte) : accumulate literal bytes until \x1b[201~.
# Bytes are stored verbatim in IN_pbuf (no UTF-8 decoding); on a partial
# terminator mismatch the matched \x1b prefix and the current byte are appended.
.Lpaste:
    mov eax, [rdi + IN_pmatch]
    test eax, eax
    jz .Lp_start
    lea r9, [rip + .Lterm]
    movzx ecx, byte ptr [r9 + rax]
    cmp esi, ecx
    jne .Lp_mismatch
    inc eax
    mov [rdi + IN_pmatch], eax
    cmp eax, 6
    jne .Lp_one
    mov dword ptr [rdi + IN_pmatch], 0
    mov dword ptr [rdi + IN_state], IN_GROUND
    sub rsp, 8
    call .Lemit_paste            # exactly one K_PASTE carrying IN_pbuf
    add rsp, 8
.Lp_one:
    mov eax, 1
    ret
.Lp_start:
    cmp esi, 0x1b
    je .Lp_esc
    jmp .Lp_fresh
.Lp_esc:
    mov dword ptr [rdi + IN_pmatch], 1
    mov eax, 1
    ret
.Lp_mismatch:
    sub rsp, 24                  # rsp is 16-byte aligned for the calls below
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov dword ptr [rsp + 16], 0
.Lp_flush:
    mov eax, [rsp + 16]
    mov rdi, [rsp]
    cmp eax, [rdi + IN_pmatch]
    jae .Lp_flush_done
    lea r9, [rip + .Lterm]
    movzx esi, byte ptr [r9 + rax]
    add rdi, IN_pbuf             # append the matched \x1b prefix verbatim
    call sb_push_byte
    inc dword ptr [rsp + 16]
    jmp .Lp_flush
.Lp_flush_done:
    mov rdi, [rsp]
    mov dword ptr [rdi + IN_pmatch], 0
    mov esi, [rsp + 8]
    add rsp, 24
    jmp .Lp_fresh
.Lp_fresh:
    cmp esi, 0x1b
    je .Lp_esc
    sub rsp, 8
    add rdi, IN_pbuf             # append the current byte verbatim
    call sb_push_byte
    add rsp, 8
    mov eax, 1
    ret

# ---------------------------------------------------------------- API
# input_free(in): release every heap buffer the parser owns: any K_PASTE
# payloads still queued in the ring, an in-flight paste accumulator, and the
# last popped paste payload.  Safe on a freshly zeroed struct.
FN input_free
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, [rbx + IN_count]
    mov r13d, [rbx + IN_head]
1:  test r12d, r12d
    jz 2f
    mov eax, r13d
    and eax, IN_MASK
    shl rax, 5
    lea rdi, [rbx + IN_ring]
    add rdi, rax
    cmp dword ptr [rdi], K_PASTE
    jne 3f
    mov rdi, [rdi + 16]          # event paste payload
    call mem_free
3:  inc r13d
    dec r12d
    jmp 1b
2:  lea rdi, [rbx + IN_pbuf]
    call sb_free
    mov rdi, [rbx + IN_paste_prev]
    call mem_free
    mov qword ptr [rbx + IN_paste_prev], 0
    xor eax, eax
    EPILOGUE

# input_init(in)
FN input_init
    PROLOGUE 16
    mov rbx, rdi
    call input_free              # release a previous life's buffers before zero
    mov rdi, rbx
    xor eax, eax
    mov ecx, IN_SIZE
    rep stosb
    EPILOGUE

# input_feed(in, ptr, len)
FN input_feed
    PROLOGUE 0
    test rdx, rdx
    jz .Lif_done
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
.Lif_loop:
    movzx esi, byte ptr [r13]
    mov eax, [r12 + IN_state]
    test eax, eax
    jz .Lif_ground
    cmp eax, IN_ESC
    je .Lif_esc
    cmp eax, IN_CSI
    je .Lif_csi
    cmp eax, IN_SS3
    je .Lif_ss3
    cmp eax, IN_STR
    je .Lif_str
    mov rdi, r12
    call .Lpaste
    jmp .Lif_next
.Lif_ground:
    mov rdi, r12
    call .Lground
    test eax, eax
    jnz .Lif_next
    jmp .Lif_loop               # .Lutf8 asked to reprocess the byte
.Lif_esc:
    mov dword ptr [r12 + IN_esc_armed], 0
    cmp esi, 0x1b                # ESC ESC -> K_ESC, stay in ESC
    jne .Lif_esc_seq
    mov esi, K_ESC
    xor edx, edx
    xor ecx, ecx
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_esc_seq:
    cmp esi, 0x5b                # '['
    je .Lif_csi_start
    cmp esi, 0x4f                # 'O'
    je .Lif_ss3_start
    cmp esi, 0x5d                # ']' OSC
    je .Lif_str_start
    cmp esi, 0x50                # 'P' DCS
    je .Lif_str_start
    cmp esi, 0x5f                # '_' APC
    je .Lif_str_start
    mov dword ptr [r12 + IN_state], IN_GROUND
    # ESC-prefixed legacy keys (IN_ESC branch): Alt+Enter,
    # Alt+Backspace, Alt+Tab, and Ctrl+Alt+<letter> for the remaining control
    # bytes, all with the alt flag set.
    cmp esi, 0x0d
    je .Lif_alt_enter
    cmp esi, 0x0a
    je .Lif_alt_enter
    cmp esi, 0x7f
    je .Lif_alt_bs
    cmp esi, 0x08
    je .Lif_alt_bs
    cmp esi, 0x09
    je .Lif_alt_tab
    cmp esi, 0x20
    jb .Lif_alt_ctrl
    cmp esi, 0x80
    jae .Lif_alt_utf
    mov edx, esi
    mov ecx, 1                   # alt+printable
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_alt_enter:
    mov esi, K_ENTER
    xor edx, edx
    mov ecx, 1
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_alt_bs:
    mov esi, K_BACKSPACE
    xor edx, edx
    mov ecx, 1
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_alt_tab:
    mov esi, K_TAB
    xor edx, edx
    mov ecx, 1
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_alt_ctrl:
    # base letter: 0 -> space, 27..31 -> @.._, else 'a'+b-1
    mov edx, esi
    test edx, edx
    jz .Lif_alt_ctrl_go
    cmp edx, 27
    jae .Lif_alt_ctrl_high
    mov eax, edx
    add eax, 'a' - 1
    mov edx, eax
    jmp .Lif_alt_ctrl_go
.Lif_alt_ctrl_high:
    add edx, 0x40
.Lif_alt_ctrl_go:
    mov esi, edx                 # key == cp for character events
    mov ecx, 5                   # CTRL | ALT
    mov rdi, r12
    call .Lemit
    jmp .Lif_next
.Lif_alt_utf:
    mov edx, 1
    mov rdi, r12
    call .Lutf8
    test eax, eax
    jnz .Lif_next
    movzx esi, byte ptr [r13]
    mov rdi, r12
    call .Lground
    jmp .Lif_next
.Lif_csi_start:
    mov dword ptr [r12 + IN_state], IN_CSI
    mov dword ptr [r12 + IN_esc_armed], 0
    mov dword ptr [r12 + IN_np], 0
    mov dword ptr [r12 + IN_num], 0
    mov dword ptr [r12 + IN_hasnum], 0
    jmp .Lif_next
.Lif_ss3_start:
    mov dword ptr [r12 + IN_state], IN_SS3
    mov dword ptr [r12 + IN_esc_armed], 0
    jmp .Lif_next
.Lif_str_start:
    mov dword ptr [r12 + IN_state], IN_STR
    mov dword ptr [r12 + IN_stresc], 0
    jmp .Lif_next
.Lif_csi:
    mov dword ptr [r12 + IN_esc_armed], 0
    mov rdi, r12
    call .Lcsi
    jmp .Lif_next
.Lif_ss3:
    mov dword ptr [r12 + IN_esc_armed], 0
    mov rdi, r12
    call .Lss3
    jmp .Lif_next
.Lif_str:
    mov rdi, r12
    call .Lstr
    jmp .Lif_next
.Lif_next:
    inc r13
    dec r14
    jnz .Lif_loop
.Lif_done:
    EPILOGUE

# input_idle(in, now_ms): arm/fire the 50 ms lone-ESC and incomplete-CSI/SS3
# timeout.  A fresh byte in feed disarms the timer, so the deadline measures
# "no following byte within 50 ms".  Call it from the shell's poll tick.
FN input_idle
    PROLOGUE 0
    mov rbx, rdi                 # in
    mov r12, rsi                 # now_ms
    mov eax, [rbx + IN_state]
    test eax, eax
    jz .Lidle_done
    cmp eax, IN_ESC
    je .Lidle_partial
    cmp eax, IN_CSI
    je .Lidle_partial
    cmp eax, IN_SS3
    je .Lidle_partial
    jmp .Lidle_done
.Lidle_partial:
    cmp dword ptr [rbx + IN_esc_armed], 0
    jne .Lidle_check
    mov dword ptr [rbx + IN_esc_armed], 1
    mov [rbx + IN_esc_ms], r12
    jmp .Lidle_done
.Lidle_check:
    mov rax, r12
    sub rax, [rbx + IN_esc_ms]
    cmp rax, IN_ESC_TIMEOUT_MS
    jb .Lidle_done
    mov dword ptr [rbx + IN_esc_armed], 0
    cmp dword ptr [rbx + IN_state], IN_ESC
    jne .Lidle_drop
    mov dword ptr [rbx + IN_state], IN_GROUND
    mov rdi, rbx
    mov esi, K_ESC
    xor edx, edx
    xor ecx, ecx
    call .Lemit
    jmp .Lidle_done
.Lidle_drop:
    # incomplete CSI/SS3: drop it rather than confuse the editor
    mov dword ptr [rbx + IN_state], IN_GROUND
    mov dword ptr [rbx + IN_np], 0
    mov dword ptr [rbx + IN_num], 0
    mov dword ptr [rbx + IN_hasnum], 0
.Lidle_done:
    EPILOGUE

# input_next(in, InputEvent*) -> 1 | 0
FN input_next
    PROLOGUE 0
    mov rbx, rdi                 # in
    mov r12, rsi                 # event out
    mov eax, [rbx + IN_count]
    test eax, eax
    jz .Lin_none
    mov ecx, [rbx + IN_head]
    lea r8, [rbx + IN_ring]
    mov r9, rcx
    shl r9, 5                    # index * 32
    add r8, r9
    inc ecx
    and ecx, IN_MAXEV - 1
    mov [rbx + IN_head], ecx
    dec eax
    mov [rbx + IN_count], eax
    mov eax, [r8]
    mov [r12], eax
    mov eax, [r8 + 4]
    mov [r12 + 4], eax
    mov eax, [r8 + 8]
    mov [r12 + 8], eax
    mov eax, [r8 + 12]
    mov [r12 + 12], eax
    mov rax, [r8 + 16]
    mov [r12 + 16], rax
    mov rax, [r8 + 24]
    mov [r12 + 24], rax
    # release the payload of the previously returned paste; the consumer must
    # copy it before the next input_next call (the shell does).
    mov rdi, [rbx + IN_paste_prev]
    call mem_free
    mov qword ptr [rbx + IN_paste_prev], 0
    # a K_PASTE event's payload becomes the new single owned pointer
    cmp dword ptr [r12], K_PASTE
    jne .Lin_ret1
    mov rax, [r12 + 16]
    mov [rbx + IN_paste_prev], rax
.Lin_ret1:
    mov eax, 1
    EPILOGUE
.Lin_none:
    # A pending lone ESC (or partial CSI/SS3) is not flushed here: input_idle
    # emits K_ESC or drops the incomplete sequence once the 50 ms window closes.
    xor eax, eax
    EPILOGUE
