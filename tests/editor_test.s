.include "opcode.inc"
# editor/input unit test.  Golden output: tests/data/editor_test.expected
#
# Drives src/tui/editor.s + src/tui/input.s.  InputEvent is 32 bytes:
#   key 0, cp 4, mods 8, pad 12, paste 16, paste_len 24.
# Bracketed paste now arrives as one K_PASTE event carrying raw bytes; the test
# hands it to editor_paste (never to editor_key).

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

.equ MOD_ALT,   1
.equ MOD_SHIFT, 2
.equ MOD_CTRL,  4

.bss
.p2align 4
ed:   .zero 2048
.p2align 4
ed2:  .zero 2048
.p2align 4
ed3:  .zero 2048
.p2align 4
ed4:  .zero 2048
.p2align 4
inp:  .zero 4096
.p2align 4
ev:   .zero 64
.p2align 4
tbuf: .zero 1024

.section .rodata
.Lnl:          .byte 10
.Lhello:       .ascii "hello"
.Lworld:       .ascii "world"
.Lhello_nl:    .ascii "hello\n"
.Lhello_world: .ascii "hello\nworld"
.Lhello_space: .ascii "hello world"
.Lhello_word:  .ascii "hello\nword"
.Llo:          .ascii "lo"
.Lott:         .ascii "one two three"
.Lott8:        .ascii "one two "
.Lone_sp:      .ascii "one "
.Lone_killed:  .ascii " two three"
.Labcdef:      .ascii "abcdef"
.Labc:         .ascii "abc"
.Labc_def_ghi: .ascii "abc\ndef\nghi"
.Labc_def_nl:  .ascii "abc\ndef\n"
.Labc_nl:      .ascii "abc\n"
.Lfirst:       .ascii "first"
.Lsecond:      .ascii "second"
.Lthird:       .ascii "third"
.Lone:         .ascii "one"
.Ltwo:         .ascii "two"
.Lthree:       .ascii "three"
.Llive:        .ascii "live"
.Lmulti:       .ascii "a\nb"
.Lb:           .ascii "b"
.Lempty:       .asciz ""
.Lab:          .ascii "ab"
.Labcd:        .ascii "abcd"
.Labdc:        .ascii "abdc"
.Lba:          .ascii "ba"
.Lctrlw:       .byte 0x17
.Lalt:         .byte 0x1b
.Lutf8a:       .byte 0xc3
.Lutf8b:       .byte 0xa9
.Ltab_ab:      .ascii "a\tb"
.Ltab_exp:     .ascii "a   b"
.Lcjk:         .byte 0xe4,0xbd,0xa0, 0xe5,0xa5,0xbd, 0xe4,0xb8,0x96, 0xe7,0x95,0x8c
.Lmix:         .ascii "ab"
               .byte 0xe4,0xbd,0xa0, 0xe5,0xa5,0xbd
               .ascii "cd"
.Lcrlf_paste:  .byte 'a',0x0d,0x0a,'b',0x0d,0x0a
.Lcrlf_exp:    .ascii "a\nb\n"
.Lpaste12:
               .ascii "l01\nl02\nl03\nl04\nl05\nl06\n"
               .ascii "l07\nl08\nl09\nl10\nl11\nl12"
.Lpaste12e:
.Lmarker1:     .asciz "[Pasted text #1 +12 lines]"
.Lliteral:     .asciz "[Pasted text #2 +3 lines]"
.Lnomatch:     .asciz "@zzzznomatch"
.Lbuilddir:    .asciz "build"
.Lhistpath:    .asciz "build/editor_test.hist"
.Lhistpath2:   .asciz "build/editor_test.hist2"
.Lhistfile:    .ascii "first\nsecond\nsecond\n"
.Lrawfile:     .ascii "one\r\ntwo\r\ntwo\r\nthree\r\n"
.Lrawfilee:
.Leseq1:       .byte 0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x33, 0x7e, 0x1b
.Leseq1e:
.Leseq2:       .byte 0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x43
.Leseq2e:
.Lss3:         .byte 0x1b, 0x4f, 0x48
.Lcsi_unknown: .byte 0x1b, 0x5b, 0x39, 0x39, 0x58
.Lcsi_unke:
.Lcsi_cont:    .byte 0x5b, 0x41                            # "[A" after a lone ESC
.Lkitty_enter: .byte 0x1b,0x5b,0x31,0x33,0x3b,0x35,0x75     # ESC [ 1 3 ; 5 u
.Lkitty_char:  .byte 0x1b,0x5b,0x39,0x38,0x3b,0x35,0x75     # ESC [ 9 8 ; 5 u
.Llegacy_left: .byte 0x1b,0x5b,0x35,0x44                    # ESC [ 5 D
.Llegacy_up:   .byte 0x1b,0x5b,0x33,0x41                    # ESC [ 3 A
.Linsert:      .byte 0x1b,0x5b,0x32,0x7e                    # ESC [ 2 ~
.Lf1_ss3:      .byte 0x1b,0x4f,0x50                         # ESC O P
.Lf1_csi:      .byte 0x1b,0x5b,0x31,0x31,0x7e               # ESC [ 1 1 ~
.Lcrlf:        .byte 0x0d,0x0a
.Lcr:          .byte 0x0d
.Loverlong:    .byte 0xe0,0x80,0x80                          # overlong U+0000
.Lsurrogate:   .byte 0xed,0xa0,0x80                          # surrogate U+D800
.Ltoobig:      .byte 0xf4,0x90,0x80,0x80                     # > U+10FFFF
.Lpaste_seq:
               .byte 0x1b,0x5b,0x32,0x30,0x30,0x7e
               .ascii "hello"
               .byte 0x1b,0x5b,0x32,0x30,0x31,0x7e
.Lpaste_seqe:
.Lok_type:     .asciz "editor type ok"
.Lok_keys:     .asciz "editor keys ok"
.Lok_words:    .asciz "editor words ok"
.Lok_kill:     .asciz "editor kill ring ok"
.Lok_motion:   .asciz "editor motion ok"
.Lok_paste:    .asciz "editor paste ok"
.Lok_wrap:     .asciz "editor wrap ok"
.Lok_hist:     .asciz "editor history ok"
.Lok_histfile: .asciz "editor history file ok"
.Lok_complete: .asciz "editor complete ok"
.Lok_input:    .asciz "input ok"
.Lok_split:    .asciz "input split ok"
.Ldone:        .asciz "editor done"
.Lfailmsg:     .asciz "FAIL editor_test"
.text

print_line:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 1
    call write_all
    lea rsi, [rip + .Lnl]
    mov edx, 1
    mov edi, 1
    call write_all
    add rsp, 8
    pop r12
    pop rbx
    ret



# check_text(rdi=ed, rsi=ptr, rdx=len) -> eax 1|0
check_text:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rsi
    mov r12, rdx
    call editor_text
    cmp rdx, r12
    jne 1f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memeq
    jmp 2f
1:  xor eax, eax
2:  add rsp, 8
    pop r12
    pop rbx
    ret

# pump(rdi=in, rsi=ed) -> eax number of events consumed.  K_PASTE goes to
# editor_paste, everything else to editor_key.
pump:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  mov rdi, rbx
    lea rsi, [rip + ev]
    call input_next
    test eax, eax
    jz 2f
    inc r13d
    mov eax, [rip + ev]
    cmp eax, K_PASTE
    jne 3f
    mov rdi, r12
    mov rsi, [rip + ev + 16]
    mov rdx, [rip + ev + 24]
    call editor_paste
    jmp 1b
3:  mov rdi, r12
    mov esi, [rip + ev]
    mov edx, [rip + ev + 4]
    mov ecx, [rip + ev + 8]
    call editor_key
    jmp 1b
2:  mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

# feed1(rdi=in, rsi=ptr, rdx=len): feed one byte at a time
feed1:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call input_feed
    inc r12
    dec r13
    jmp 1b
2:  pop r13
    pop r12
    pop rbx
    ret

# next_is(rdi=in, esi=key, edx=cp, ecx=mods) -> eax 1 if the next event matches
next_is:
    PROLOGUE 0
    mov ebx, esi
    mov r12d, edx
    mov r13d, ecx
    lea rsi, [rip + ev]
    call input_next
    test eax, eax
    jz 1f
    cmp dword ptr [rip + ev], ebx
    jne 1f
    cmp dword ptr [rip + ev + 4], r12d
    jne 1f
    cmp dword ptr [rip + ev + 8], r13d
    jne 1f
    mov eax, 1
    jmp 2f
1:  xor eax, eax
2:  EPILOGUE

# next_empty(rdi=in) -> eax 1 if the queue (and a deferred ESC) is empty
next_empty:
    PROLOGUE 0
    mov rbx, rdi
    lea rsi, [rip + ev]
    call input_next
    test eax, eax
    jnz 1f
    mov eax, 1
    jmp 2f
1:  xor eax, eax
2:  EPILOGUE

# ekey(rdi=ed, esi=key, edx=cp, ecx=mods)
ekey:
    jmp editor_key

# move_left_n(rdi=ed, esi=n): press Left n times
move_left_n:
    PROLOGUE 0
    mov r12, rdi
    mov ebx, esi
1:  test ebx, ebx
    jz 2f
    mov rdi, r12
    mov esi, K_LEFT
    xor edx, edx
    xor ecx, ecx
    call editor_key
    dec ebx
    jmp 1b
2:  EPILOGUE

# take_eq(rdi=ed, rsi=ptr, rdx=len) -> eax 1|0: editor_take, compare, free.
take_eq:
    PROLOGUE 0
    mov r12, rsi
    mov r13, rdx
    call editor_take
    mov r14, rax
    mov rdi, rax
    call strlen
    cmp rax, r13
    jne 1f
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memeq
    mov r15d, eax
    jmp 2f
1:  xor r15d, r15d
2:  mov rdi, r14
    call mem_free
    mov eax, r15d
    EPILOGUE

# check_file(rdi=path, rsi=ptr, rdx=len) -> eax 1|0
check_file:
    PROLOGUE 0
    mov r12, rsi
    mov r13, rdx
    xor esi, esi
    xor edx, edx
    call os_open
    test eax, eax
    js .Lcf_no
    mov r14d, eax
    mov edi, r14d
    lea rsi, [rip + tbuf]
    mov edx, 1024
    call os_read
    mov r15, rax
    mov edi, r14d
    call os_close
    cmp r15, r13
    jne .Lcf_no
    lea rdi, [rip + tbuf]
    mov rsi, r12
    mov rdx, r13
    call memeq
    EPILOGUE
.Lcf_no:
    xor eax, eax
    EPILOGUE

# write_file(rdi=path, rsi=ptr, rdx=len) -> eax 1|0
write_file:
    PROLOGUE 0
    mov r12, rsi
    mov r13, rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test eax, eax
    js .Lwf_no
    mov r14d, eax
    mov edi, r14d
    mov rsi, r12
    mov rdx, r13
    call os_write
    mov edi, r14d
    call os_close
    mov eax, 1
    EPILOGUE
.Lwf_no:
    xor eax, eax
    EPILOGUE

FN opcode_main
    PROLOGUE 0
    # caller buffers must hold the exported struct sizes; InputEvent is 32 bytes
    cmp qword ptr [rip + editor_ed_size], 2048
    ja .Lfail
    cmp qword ptr [rip + input_in_size], 4096
    ja .Lfail
    cmp qword ptr [rip + input_ev_size], 32
    jne .Lfail

    # ---------------- 1: type, Enter submits, Alt+Enter newlines ----------------
    lea rdi, [rip + ed]
    call editor_init
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + ed]
    call pump
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    # plain Enter returns 1 and inserts nothing
    lea rdi, [rip + ed]
    mov esi, K_ENTER
    mov edx, K_ENTER
    xor ecx, ecx
    call ekey
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    # Alt+Enter inserts '\n'
    lea rdi, [rip + ed]
    mov esi, K_ENTER
    mov edx, K_ENTER
    mov ecx, MOD_ALT
    call ekey
    test eax, eax
    jnz .Lfail
    # type "world"
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lworld]
    mov edx, 5
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + ed]
    call pump
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_world]
    mov edx, 11
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp eax, 2
    jne .Lfail
    cmp edx, 1
    jne .Lfail
    cmp ecx, 5
    jne .Lfail
    lea rdi, [rip + .Lok_type]
    call print_line

    # ---------------- 2: arrows, backspace, delete, selection ----------------
    # cur at end of "hello\nworld"
    lea rdi, [rip + ed]
    mov esi, K_LEFT
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    mov esi, K_BACKSPACE
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_word]
    mov edx, 10
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, K_RIGHT
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    mov esi, K_DEL                # at the end: no-op
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_word]
    mov edx, 10
    call check_text
    test eax, eax
    jz .Lfail
    mov r12d, 4                   # erase "word"
.Lbs_loop:
    lea rdi, [rip + ed]
    mov esi, K_BACKSPACE
    xor edx, edx
    xor ecx, ecx
    call ekey
    dec r12d
    jnz .Lbs_loop
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_nl]
    mov edx, 6
    call check_text
    test eax, eax
    jz .Lfail
    mov r12d, 6                   # erase "\nhello"
.Lbs_loop2:
    lea rdi, [rip + ed]
    mov esi, K_BACKSPACE
    xor edx, edx
    xor ecx, ecx
    call ekey
    dec r12d
    jnz .Lbs_loop2
    lea rdi, [rip + ed]
    mov esi, K_BACKSPACE          # at offset 0: no-op
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call check_text
    test eax, eax
    jz .Lfail
    # selection: home, shift+right x3, backspace removes "hel"
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_HOME
    xor edx, edx
    xor ecx, ecx
    call ekey
    mov r12d, 3
.Lsel_loop:
    lea rdi, [rip + ed]
    mov esi, K_RIGHT
    xor edx, edx
    mov ecx, MOD_SHIFT
    call ekey
    dec r12d
    jnz .Lsel_loop
    lea rdi, [rip + ed]
    mov esi, K_BACKSPACE
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Llo]
    mov edx, 2
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_keys]
    call print_line

    # ---------------- 3: words, home/end, ctrl-a/e ----------------
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 0x17                 # ctrl+w
    mov edx, 0x17
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott8]
    mov edx, 8
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x17
    mov edx, 0x17
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lone_sp]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x15                 # ctrl+u
    mov edx, 0x15
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+k from the middle
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labcdef]
    mov edx, 6
    call editor_set
    mov r12d, 3
.Lleft_loop:
    lea rdi, [rip + ed]
    mov esi, K_LEFT
    xor edx, edx
    xor ecx, ecx
    call ekey
    dec r12d
    jnz .Lleft_loop
    lea rdi, [rip + ed]
    mov esi, 0x0b                 # ctrl+k
    mov edx, 0x0b
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labc]
    mov edx, 3
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x15                 # ctrl+u clears the line
    mov edx, 0x15
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call check_text
    test eax, eax
    jz .Lfail
    # home/end vs ctrl-a/ctrl-e on a multiline buffer
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labc_def_ghi]
    mov edx, 11
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_END
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    mov esi, K_HOME               # start of the last line
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp edx, 2
    jne .Lfail
    cmp ecx, 0
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x01                 # ctrl+a -> start of the last line (no move)
    mov edx, 0x01
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp eax, 3
    jne .Lfail
    cmp edx, 2
    jne .Lfail
    test ecx, ecx
    jnz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x05                 # ctrl+e -> end of the last line
    mov edx, 0x05
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp edx, 2
    jne .Lfail
    cmp ecx, 3
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x15                 # ctrl+u removes "ghi"
    mov edx, 0x15
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labc_def_nl]
    mov edx, 8
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x17                 # ctrl+w removes "def\n"
    mov edx, 0x17
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labc_nl]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_words]
    call print_line

    # ---------------- 4: transpose, kill ring + yank ----------------
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labcd]
    mov edx, 4
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 0x14                 # ctrl+t at end: swap "cd"
    mov edx, 0x14
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labdc]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lab]
    mov edx, 2
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_LEFT
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed]
    mov esi, 0x14                 # ctrl+t mid-buffer: swap "ab"
    mov edx, 0x14
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lba]
    mov edx, 2
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+k kills the tail, ctrl+y yanks it back
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_space]
    mov edx, 11
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 6
    call move_left_n              # cur at offset 5
    lea rdi, [rip + ed]
    mov esi, 0x0b                 # kill " world"
    mov edx, 0x0b
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x19                 # yank
    mov edx, 0x19
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_space]
    mov edx, 11
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+u kills the whole line, ctrl+y restores it
    lea rdi, [rip + ed]
    mov esi, 0x15
    mov edx, 0x15
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x19
    mov edx, 0x19
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello_space]
    mov edx, 11
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+w kill word, ctrl+y yank
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 0x17
    mov edx, 0x17
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott8]
    mov edx, 8
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed]
    mov esi, 0x19
    mov edx, 0x19
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_kill]
    call print_line

    # ---------------- 5: word motion, alt+d, ctrl+delete, ctrl-home/end -------
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_LEFT
    xor edx, edx
    mov ecx, MOD_ALT
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 8
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, K_RIGHT
    xor edx, edx
    mov ecx, MOD_ALT
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 13
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, K_LEFT
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 8
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, K_RIGHT
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 13
    jne .Lfail
    # alt+b / alt+f are the same word motions
    lea rdi, [rip + ed]
    mov esi, 'b'
    mov edx, 'b'
    mov ecx, MOD_ALT
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 8
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, 'f'
    mov edx, 'f'
    mov ecx, MOD_ALT
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp ecx, 13
    jne .Lfail
    # alt+d kills the word at the caret
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_HOME
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 'd'
    mov edx, 'd'
    mov ecx, MOD_ALT
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lone_killed]
    mov edx, 10
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+delete kills the same forward word
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lott]
    mov edx, 13
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_HOME
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, K_DEL
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lone_killed]
    mov edx, 10
    call check_text
    test eax, eax
    jz .Lfail
    # ctrl+home / ctrl+end span the whole buffer
    lea rdi, [rip + ed]
    lea rsi, [rip + .Labc_def_ghi]
    mov edx, 11
    call editor_set
    lea rdi, [rip + ed]
    mov esi, K_HOME
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    test edx, edx
    jnz .Lfail
    test ecx, ecx
    jnz .Lfail
    lea rdi, [rip + ed]
    mov esi, K_END
    xor edx, edx
    mov ecx, MOD_CTRL
    call ekey
    lea rdi, [rip + ed]
    mov esi, 80
    call editor_lines
    cmp edx, 2
    jne .Lfail
    cmp ecx, 3
    jne .Lfail
    lea rdi, [rip + .Lok_motion]
    call print_line

    # ---------------- 6: paste: K_PASTE, CRLF, collapse, expansion -----------
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lpaste_seq]
    mov edx, .Lpaste_seqe - .Lpaste_seq
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + ev]
    call input_next
    test eax, eax
    jz .Lfail
    cmp dword ptr [rip + ev], K_PASTE
    jne .Lfail
    cmp qword ptr [rip + ev + 24], 5
    jne .Lfail
    lea rdi, [rip + ed]
    call editor_clear
    lea rdi, [rip + ed]
    mov rsi, [rip + ev + 16]
    mov rdx, [rip + ev + 24]
    call editor_paste
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    # CRLF is normalised to LF and short pastes insert directly
    lea rdi, [rip + ed]
    call editor_clear
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lcrlf_paste]
    mov edx, 6
    call editor_paste
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lcrlf_exp]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    # a >10-line paste collapses to a marker
    lea rdi, [rip + ed]
    call editor_clear
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lpaste12]
    mov edx, .Lpaste12e - .Lpaste12
    call editor_paste
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lmarker1]
    mov edx, 26
    call check_text
    test eax, eax
    jz .Lfail
    # editor_take expands the marker and clears the buffer
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lpaste12]
    mov edx, .Lpaste12e - .Lpaste12
    call take_eq
    test eax, eax
    jz .Lfail
    # an out-of-range marker is left literal
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lliteral]
    mov edx, 25
    call editor_set
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lliteral]
    mov edx, 25
    call take_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_paste]
    call print_line

    # ---------------- 7: tab expansion, display-width wrapping ---------------
    lea rdi, [rip + ed]
    lea rsi, [rip + .Ltab_ab]
    mov edx, 3
    call editor_set
    lea rdi, [rip + ed]
    lea rsi, [rip + .Ltab_exp]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    # 4 CJK cells (width 2 each) wrap at width 6 (inner 5): 2 rows, caret (1,4)
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lcjk]
    mov edx, 12
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 6
    call editor_lines
    cmp eax, 2
    jne .Lfail
    cmp edx, 1
    jne .Lfail
    cmp ecx, 4
    jne .Lfail
    lea rdi, [rip + ed]
    mov esi, 6
    call editor_visual_rows
    cmp eax, 4
    jne .Lfail
    # an exactly-filling wide glyph stays; the next narrow glyph wraps (inner 6)
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lmix]
    mov edx, 10
    call editor_set
    lea rdi, [rip + ed]
    mov esi, 7
    call editor_lines
    cmp eax, 2
    jne .Lfail
    cmp edx, 1
    jne .Lfail
    cmp ecx, 2
    jne .Lfail
    # editor_empty
    lea rdi, [rip + ed]
    call editor_clear
    lea rdi, [rip + ed]
    call editor_empty
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lb]
    mov edx, 1
    call editor_set
    lea rdi, [rip + ed]
    call editor_empty
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lok_wrap]
    call print_line

    # ---------------- 8: in-memory history (oldest-first, live buffer) -------
    lea rdi, [rip + ed2]
    call editor_init
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lfirst]
    mov edx, 5
    call editor_history_add
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lsecond]
    mov edx, 6
    call editor_history_add
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lthird]
    mov edx, 5
    call editor_history_add
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lthird]
    mov edx, 5
    call editor_history_add    # duplicate newest: no-op
    cmp eax, 1
    je .Lfail
    # browsing Up/Down with a live buffer
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Llive]
    mov edx, 4
    call editor_set
    lea rdi, [rip + ed2]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lthird]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed2]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lsecond]
    mov edx, 6
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed2]
    mov esi, K_DOWN
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Lthird]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed2]
    mov esi, K_DOWN
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Llive]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed2]
    mov esi, K_DOWN
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed2]
    lea rsi, [rip + .Llive]
    mov edx, 4
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_hist]
    call print_line

    # ---------------- 9: history disk round-trip -----------------------------
    lea rdi, [rip + .Lhistpath]
    call os_unlink
    lea rdi, [rip + ed3]
    call editor_init
    lea rdi, [rip + ed3]
    lea rsi, [rip + .Lhistpath]
    lea rdx, [rip + .Lfirst]
    mov ecx, 5
    call editor_history_append
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + ed3]
    lea rsi, [rip + .Lhistpath]
    lea rdx, [rip + .Lsecond]
    mov ecx, 6
    call editor_history_append
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + ed3]
    lea rsi, [rip + .Lhistpath]
    lea rdx, [rip + .Lsecond]
    mov ecx, 6
    call editor_history_append    # duplicate: written, collapsed again on load
    lea rdi, [rip + ed3]
    lea rsi, [rip + .Lhistpath]
    lea rdx, [rip + .Lmulti]
    mov ecx, 3
    call editor_history_append    # multi-line is not persisted
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + ed3]
    lea rsi, [rip + .Lhistpath]
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
    call editor_history_append    # empty is not persisted
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lhistpath]
    lea rsi, [rip + .Lhistfile]
    mov edx, 20
    call check_file
    test eax, eax
    jz .Lfail
    # a fresh editor loads and browses the persisted list
    lea rdi, [rip + ed4]
    call editor_init
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lhistpath]
    call editor_history_load
    lea rdi, [rip + ed4]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lsecond]
    mov edx, 6
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed4]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lfirst]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    # load strips CR and drops consecutive duplicates
    lea rdi, [rip + .Lhistpath2]
    call os_unlink
    lea rdi, [rip + .Lhistpath2]
    lea rsi, [rip + .Lrawfile]
    mov edx, .Lrawfilee - .Lrawfile
    call write_file
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed4]
    call editor_init
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lhistpath2]
    call editor_history_load
    lea rdi, [rip + ed4]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lthree]
    mov edx, 5
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed4]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Ltwo]
    mov edx, 3
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ed4]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call ekey
    lea rdi, [rip + ed4]
    lea rsi, [rip + .Lone]
    mov edx, 3
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lhistpath]
    call os_unlink
    lea rdi, [rip + .Lhistpath2]
    call os_unlink
    lea rdi, [rip + .Lok_histfile]
    call print_line

    # ---------------- 10: @file completion no-match is a no-op ---------------
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lnomatch]
    mov edx, 12
    call editor_set
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lbuilddir]
    call editor_complete
    lea rdi, [rip + ed]
    lea rsi, [rip + .Lnomatch]
    mov edx, 12
    call check_text
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_complete]
    call print_line

    # ---------------- 11: input parser: CSI/SS3/ESC timeout ----------------
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Leseq1]
    mov edx, .Leseq1e - .Leseq1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, K_DOWN
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, K_DEL
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # the trailing lone ESC is held: input_next must not flush it
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # idle timer: nothing before 50 ms, K_ESC at 50 ms
    lea rdi, [rip + inp]
    mov esi, 1000
    call input_idle
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, 1049
    call input_idle
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, 1050
    call input_idle
    lea rdi, [rip + inp]
    mov esi, K_ESC
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # a lone ESC is deferred, then the idle timer fires it
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lalt]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, 2000
    call input_idle
    lea rdi, [rip + inp]
    mov esi, 2050
    call input_idle
    lea rdi, [rip + inp]
    mov esi, K_ESC
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # ESC in one read + continuation in a later read = one arrow, not ESC + lit
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lalt]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 3000
    call input_idle
    lea rdi, [rip + inp]
    mov esi, 3020
    call input_idle
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lcsi_cont]
    mov edx, 2
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_UP
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # the old deadline must not emit a stray ESC afterwards
    lea rdi, [rip + inp]
    mov esi, 3100
    call input_idle
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # SS3 home
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lss3]
    mov edx, 3
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_HOME
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # SS3 F1
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lf1_ss3]
    mov edx, 3
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_F1
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # CSI F1
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lf1_csi]
    mov edx, 5
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_F1
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # CSI 2~ Insert
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Linsert]
    mov edx, 4
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_INSERT
    xor edx, edx
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # legacy CSI 5D = Ctrl+Left
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Llegacy_left]
    mov edx, 4
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_LEFT
    xor edx, edx
    mov ecx, MOD_CTRL
    call next_is
    test eax, eax
    jz .Lfail
    # legacy CSI 3A = Alt+Up
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Llegacy_up]
    mov edx, 4
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_UP
    xor edx, edx
    mov ecx, MOD_ALT
    call next_is
    test eax, eax
    jz .Lfail
    # kitty CSI 13;5u = Ctrl+Enter
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lkitty_enter]
    mov edx, 7
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_ENTER
    xor edx, edx
    mov ecx, MOD_CTRL
    call next_is
    test eax, eax
    jz .Lfail
    # kitty CSI 98;5u = Ctrl+b character
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lkitty_char]
    mov edx, 7
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 98
    mov edx, 98
    mov ecx, MOD_CTRL
    call next_is
    test eax, eax
    jz .Lfail
    # CRLF collapses to one Enter; a bare LF and a bare CR are Enter too
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lcrlf]
    mov edx, 2
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_ENTER
    mov edx, K_ENTER
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_ENTER
    mov edx, K_ENTER
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lcr]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, K_ENTER
    mov edx, K_ENTER
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # overlong E0 80 80 -> three U+FFFD (strict one-byte consumption)
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Loverlong]
    mov edx, 3
    call input_feed
    mov r12d, 3
.Lol_loop:
    lea rdi, [rip + inp]
    mov esi, 0xfffd
    mov edx, 0xfffd
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    dec r12d
    jnz .Lol_loop
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # surrogate ED A0 80 -> three U+FFFD
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lsurrogate]
    mov edx, 3
    call input_feed
    mov r12d, 3
.Lsg_loop:
    lea rdi, [rip + inp]
    mov esi, 0xfffd
    mov edx, 0xfffd
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    dec r12d
    jnz .Lsg_loop
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # F4 90 80 80 (> U+10FFFF) -> four U+FFFD
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Ltoobig]
    mov edx, 4
    call input_feed
    mov r12d, 4
.Ltb_loop:
    lea rdi, [rip + inp]
    mov esi, 0xfffd
    mov edx, 0xfffd
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    dec r12d
    jnz .Ltb_loop
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # a partial UTF-8 sequence cancelled by ASCII -> U+FFFD, then the byte
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lutf8a]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lb]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 0xfffd
    mov edx, 0xfffd
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    mov esi, 'b'
    mov edx, 'b'
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_input]
    call print_line

    # ---------------- 12: input split boundaries ---------------------------
    # byte-by-byte "\x1b[1;5C": exactly one K_RIGHT with ctrl, no strays
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Leseq2]
    mov edx, .Leseq2e - .Leseq2
    call feed1
    lea rdi, [rip + inp]
    mov esi, K_RIGHT
    xor edx, edx
    mov ecx, MOD_CTRL
    call next_is
    test eax, eax
    jz .Lfail
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    # UTF-8 split across feeds -> one cp event
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lutf8a]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lutf8b]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 0xe9
    mov edx, 0xe9
    xor ecx, ecx
    call next_is
    test eax, eax
    jz .Lfail
    # alt+b
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lalt]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lb]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 'b'
    mov edx, 'b'
    mov ecx, MOD_ALT
    call next_is
    test eax, eax
    jz .Lfail
    # ctrl+byte
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lctrlw]
    mov edx, 1
    call input_feed
    lea rdi, [rip + inp]
    mov esi, 0x17
    mov edx, 0x17
    mov ecx, MOD_CTRL
    call next_is
    test eax, eax
    jz .Lfail
    # unknown CSI is swallowed
    lea rdi, [rip + inp]
    call input_init
    lea rdi, [rip + inp]
    lea rsi, [rip + .Lcsi_unknown]
    mov edx, .Lcsi_unke - .Lcsi_unknown
    call input_feed
    lea rdi, [rip + inp]
    call next_empty
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_split]
    call print_line

    lea rdi, [rip + .Ldone]
    call print_line
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lfailmsg]
    call print_line
    mov eax, 1
    EPILOGUE
