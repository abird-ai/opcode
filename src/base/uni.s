.include "opcode.inc"
# opcode base: portable Unicode helpers shared by the composer and transcript.
# Strict UTF-8 decoding and a compact wcwidth classifier, ported from
# view.s's utf8dec/view_wcwidth so composer measure and draw passes cannot
# disagree.  The width table lives here so every caller measures identically;
# see .agents/docs/tui.md for the shared-width-table contract.

# utf8_decode(ptr, len) -> rax = codepoint, rdx = bytes consumed (1..4).
# Strict: an invalid lead byte, a truncated sequence, a bad continuation, a
# surrogate, an overlong form or a value above U+10FFFF yields U+FFFD and
# consumes exactly one byte; empty input likewise yields U+FFFD, bytes 1.
# Leaf; clobbers rax/rcx/rdx/r8/r9/r10.
FN utf8_decode
    test rsi, rsi
    jz .Lvd_bad
    movzx eax, byte ptr [rdi]
    cmp eax, 0x80
    jb .Lvd_one
    cmp eax, 0xC2
    jb .Lvd_bad
    cmp eax, 0xE0
    jb .Lvd_two
    cmp eax, 0xF0
    jb .Lvd_three
    cmp eax, 0xF5
    jb .Lvd_four
    jmp .Lvd_bad
.Lvd_one:
    mov edx, 1
    ret
.Lvd_bad:
    mov eax, 0xFFFD
    mov edx, 1
    ret
.Lvd_two:
    cmp rsi, 2
    jb .Lvd_bad
    movzx ecx, byte ptr [rdi + 1]
    mov r8d, ecx
    and r8d, 0xC0
    cmp r8d, 0x80
    jne .Lvd_bad
    and eax, 0x1F
    shl eax, 6
    and ecx, 0x3F
    or eax, ecx
    mov edx, 2
    ret
.Lvd_three:
    cmp rsi, 3
    jb .Lvd_bad
    movzx ecx, byte ptr [rdi + 1]
    movzx r8d, byte ptr [rdi + 2]
    mov r9d, ecx
    and r9d, 0xC0
    cmp r9d, 0x80
    jne .Lvd_bad
    mov r9d, r8d
    and r9d, 0xC0
    cmp r9d, 0x80
    jne .Lvd_bad
    and eax, 0x0F
    shl eax, 12
    and ecx, 0x3F
    shl ecx, 6
    or eax, ecx
    and r8d, 0x3F
    or eax, r8d
    cmp eax, 0x800
    jb .Lvd_bad
    cmp eax, 0xD800
    jb .Lvd_three_ok
    cmp eax, 0xDFFF
    jbe .Lvd_bad
.Lvd_three_ok:
    mov edx, 3
    ret
.Lvd_four:
    cmp rsi, 4
    jb .Lvd_bad
    movzx ecx, byte ptr [rdi + 1]
    movzx r8d, byte ptr [rdi + 2]
    movzx r9d, byte ptr [rdi + 3]
    mov r10d, ecx
    and r10d, 0xC0
    cmp r10d, 0x80
    jne .Lvd_bad
    mov r10d, r8d
    and r10d, 0xC0
    cmp r10d, 0x80
    jne .Lvd_bad
    mov r10d, r9d
    and r10d, 0xC0
    cmp r10d, 0x80
    jne .Lvd_bad
    and eax, 0x07
    shl eax, 18
    and ecx, 0x3F
    shl ecx, 12
    or eax, ecx
    and r8d, 0x3F
    shl r8d, 6
    or eax, r8d
    and r9d, 0x3F
    or eax, r9d
    cmp eax, 0x10000
    jb .Lvd_bad
    cmp eax, 0x10FFFF
    ja .Lvd_bad
    mov edx, 4
    ret

# utf8_is_combining(cp edi) -> eax 1|0: a genuine zero-width combining mark.
# The merged zero-width table also carries the Cf format characters, which
# must never be drawn nor attached to a base cell; .Lwc_format_ranges lists
# that subset (Cf plus the soft hyphen and the Mongolian vowel separator).
# C0/DEL/C1 controls are not combining either.  Leaf; clobbers eax/edi/r8.
FN utf8_is_combining
    cmp edi, 0x20
    jb .Lic_no
    cmp edi, 0x7f
    je .Lic_no
    cmp edi, 0x80
    jb .Lic_check
    cmp edi, 0x9f
    jbe .Lic_no
.Lic_check:
    lea r8, [rip + .Lwc_format_ranges]
.Lic_floop:
    mov eax, [r8]
    cmp eax, -1
    je .Lic_zero
    cmp edi, eax
    jb .Lic_fnext
    mov eax, [r8 + 4]
    cmp edi, eax
    jbe .Lic_no
.Lic_fnext:
    add r8, 8
    jmp .Lic_floop
.Lic_zero:
    lea r8, [rip + .Lwc_zero_ranges]
.Lic_zloop:
    mov eax, [r8]
    cmp eax, -1
    je .Lic_no
    cmp edi, eax
    jb .Lic_znext
    mov eax, [r8 + 4]
    cmp edi, eax
    jbe .Lic_yes
.Lic_znext:
    add r8, 8
    jmp .Lic_zloop
.Lic_yes:
    mov eax, 1
    ret
.Lic_no:
    xor eax, eax
    ret

# utf8_wcwidth(cp edi) -> eax: 0 combining/zero-width or format, 2 East-Asian
# wide/fullwidth or emoji, else 1.  This is the single width table shared by
# the composer, transcript and grid (view_wcwidth defers here).  Leaf;
# clobbers eax/edi/r8.
FN utf8_wcwidth
    cmp edi, 0x20
    jb .Lwc_zero
    cmp edi, 0x7f
    je .Lwc_zero
    cmp edi, 0x80
    jb .Lwc_zero_check
    cmp edi, 0x9f
    jbe .Lwc_zero
.Lwc_zero_check:
    lea r8, [rip + .Lwc_zero_ranges]
.Lwc_zloop:
    mov eax, [r8]
    cmp eax, -1
    je .Lwc_wide_check
    cmp edi, eax
    jb .Lwc_znext
    mov eax, [r8 + 4]
    cmp edi, eax
    jbe .Lwc_zero
.Lwc_znext:
    add r8, 8
    jmp .Lwc_zloop
.Lwc_wide_check:
    lea r8, [rip + .Lwc_wide_ranges]
.Lwc_wloop:
    mov eax, [r8]
    cmp eax, -1
    je .Lwc_one
    cmp edi, eax
    jb .Lwc_wnext
    mov eax, [r8 + 4]
    cmp edi, eax
    jbe .Lwc_two
.Lwc_wnext:
    add r8, 8
    jmp .Lwc_wloop
.Lwc_one:
    mov eax, 1
    ret
.Lwc_two:
    mov eax, 2
    ret
.Lwc_zero:
    xor eax, eax
    ret

.section .rodata
# Zero-width codepoints (combining marks, format controls). Pair table ending
# in -1.  See utf8_wcwidth.
.p2align 3
# Cf formatting codepoints plus U+00AD soft hyphen and U+180E Mongolian vowel
# separator: zero width, never drawn.
.Lwc_format_ranges:
    .long 0x00AD, 0x00AD
    .long 0x180E, 0x180E
    .long 0x200B, 0x200F
    .long 0x202A, 0x202E
    .long 0x2060, 0x2064
    .long 0x2066, 0x206F
    .long 0xFEFF, 0xFEFF
    .long -1

.p2align 3
.Lwc_zero_ranges:
    .long 0x00AD, 0x00AD
    .long 0x0300, 0x036F
    .long 0x0483, 0x0489
    .long 0x0591, 0x05BD
    .long 0x05BF, 0x05BF
    .long 0x05C1, 0x05C2
    .long 0x05C4, 0x05C5
    .long 0x05C7, 0x05C7
    .long 0x0610, 0x061A
    .long 0x064B, 0x065F
    .long 0x0670, 0x0670
    .long 0x06D6, 0x06DC
    .long 0x06DF, 0x06E4
    .long 0x06E7, 0x06E8
    .long 0x06EA, 0x06ED
    .long 0x0711, 0x0711
    .long 0x0730, 0x074A
    .long 0x07A6, 0x07B0
    .long 0x07EB, 0x07F3
    .long 0x0816, 0x0819
    .long 0x081B, 0x0823
    .long 0x0825, 0x0827
    .long 0x0829, 0x082D
    .long 0x0859, 0x085B
    .long 0x08E3, 0x0903
    .long 0x093A, 0x093C
    .long 0x093E, 0x094F
    .long 0x0951, 0x0957
    .long 0x0962, 0x0963
    .long 0x0981, 0x0983
    .long 0x09BC, 0x09BC
    .long 0x09BE, 0x09C4
    .long 0x09C7, 0x09C8
    .long 0x09CB, 0x09CD
    .long 0x09D7, 0x09D7
    .long 0x09E2, 0x09E3
    .long 0x0A01, 0x0A03
    .long 0x0A3C, 0x0A3C
    .long 0x0A3E, 0x0A42
    .long 0x0A47, 0x0A48
    .long 0x0A4B, 0x0A4D
    .long 0x0A51, 0x0A51
    .long 0x0A70, 0x0A71
    .long 0x0A75, 0x0A75
    .long 0x0A81, 0x0A83
    .long 0x0ABC, 0x0ABC
    .long 0x0ABE, 0x0AC5
    .long 0x0AC7, 0x0AC9
    .long 0x0ACB, 0x0ACD
    .long 0x0AE2, 0x0AE3
    .long 0x0B01, 0x0B03
    .long 0x0B3C, 0x0B3C
    .long 0x0B3E, 0x0B44
    .long 0x0B47, 0x0B48
    .long 0x0B4B, 0x0B4D
    .long 0x0B56, 0x0B57
    .long 0x0B62, 0x0B63
    .long 0x0B82, 0x0B82
    .long 0x0BBE, 0x0BC2
    .long 0x0BC6, 0x0BC8
    .long 0x0BCA, 0x0BCD
    .long 0x0BD7, 0x0BD7
    .long 0x0C00, 0x0C03
    .long 0x0C3E, 0x0C44
    .long 0x0C46, 0x0C48
    .long 0x0C4A, 0x0C4D
    .long 0x0C55, 0x0C56
    .long 0x0C62, 0x0C63
    .long 0x0C81, 0x0C83
    .long 0x0CBC, 0x0CBC
    .long 0x0CBE, 0x0CC4
    .long 0x0CC6, 0x0CC8
    .long 0x0CCA, 0x0CCD
    .long 0x0CD5, 0x0CD6
    .long 0x0CE2, 0x0CE3
    .long 0x0D01, 0x0D03
    .long 0x0D3E, 0x0D44
    .long 0x0D46, 0x0D48
    .long 0x0D4A, 0x0D4D
    .long 0x0D57, 0x0D57
    .long 0x0D62, 0x0D63
    .long 0x0D82, 0x0D83
    .long 0x0DCA, 0x0DCA
    .long 0x0DCF, 0x0DD4
    .long 0x0DD6, 0x0DD6
    .long 0x0DD8, 0x0DDF
    .long 0x0DF2, 0x0DF3
    .long 0x0E31, 0x0E31
    .long 0x0E34, 0x0E3A
    .long 0x0E47, 0x0E4E
    .long 0x0EB1, 0x0EB1
    .long 0x0EB4, 0x0EB9
    .long 0x0EBB, 0x0EBC
    .long 0x0EC8, 0x0ECD
    .long 0x0F18, 0x0F19
    .long 0x0F35, 0x0F35
    .long 0x0F37, 0x0F37
    .long 0x0F39, 0x0F39
    .long 0x0F3E, 0x0F3F
    .long 0x0F71, 0x0F84
    .long 0x0F86, 0x0F87
    .long 0x0F8D, 0x0F97
    .long 0x0F99, 0x0FBC
    .long 0x0FC6, 0x0FC6
    .long 0x102B, 0x103E
    .long 0x1056, 0x1059
    .long 0x105E, 0x1060
    .long 0x1062, 0x1064
    .long 0x1067, 0x106D
    .long 0x1071, 0x1074
    .long 0x1082, 0x108D
    .long 0x108F, 0x108F
    .long 0x109A, 0x109D
    .long 0x135D, 0x135F
    .long 0x1712, 0x1714
    .long 0x1732, 0x1734
    .long 0x1752, 0x1753
    .long 0x1772, 0x1773
    .long 0x17B4, 0x17D3
    .long 0x17DD, 0x17DD
    .long 0x180B, 0x180E
    .long 0x18A9, 0x18A9
    .long 0x1920, 0x192B
    .long 0x1930, 0x193B
    .long 0x1A17, 0x1A1B
    .long 0x1A55, 0x1A5E
    .long 0x1A60, 0x1A7C
    .long 0x1A7F, 0x1A7F
    .long 0x1AB0, 0x1ABE
    .long 0x1B00, 0x1B04
    .long 0x1B34, 0x1B44
    .long 0x1B6B, 0x1B73
    .long 0x1B80, 0x1B82
    .long 0x1BA1, 0x1BAD
    .long 0x1BE6, 0x1BF3
    .long 0x1C24, 0x1C37
    .long 0x1CD0, 0x1CD2
    .long 0x1CD4, 0x1CE8
    .long 0x1CED, 0x1CED
    .long 0x1CF2, 0x1CF4
    .long 0x1CF8, 0x1CF9
    .long 0x1DC0, 0x1DFF
    .long 0x200B, 0x200F
    .long 0x202A, 0x202E
    .long 0x2060, 0x2064
    .long 0x2066, 0x206F
    .long 0x20D0, 0x20F0
    .long 0x2CEF, 0x2CF1
    .long 0x2D7F, 0x2D7F
    .long 0x2DE0, 0x2DFF
    .long 0x302A, 0x302D
    .long 0x3099, 0x309A
    .long 0xA66F, 0xA672
    .long 0xA674, 0xA67D
    .long 0xA69E, 0xA69F
    .long 0xA6F0, 0xA6F1
    .long 0xA802, 0xA802
    .long 0xA806, 0xA806
    .long 0xA80B, 0xA80B
    .long 0xA823, 0xA827
    .long 0xA880, 0xA881
    .long 0xA8B4, 0xA8C4
    .long 0xA8E0, 0xA8F1
    .long 0xA926, 0xA92D
    .long 0xA947, 0xA953
    .long 0xA980, 0xA983
    .long 0xA9B3, 0xA9C0
    .long 0xA9E5, 0xA9E5
    .long 0xAA29, 0xAA36
    .long 0xAA43, 0xAA43
    .long 0xAA4C, 0xAA4D
    .long 0xAA7B, 0xAA7D
    .long 0xAAB0, 0xAAB0
    .long 0xAAB2, 0xAAB4
    .long 0xAAB7, 0xAAB8
    .long 0xAABE, 0xAABF
    .long 0xAAC1, 0xAAC1
    .long 0xAAEB, 0xAAEF
    .long 0xAAF5, 0xAAF6
    .long 0xABE3, 0xABEA
    .long 0xABEC, 0xABED
    .long 0xFB1E, 0xFB1E
    .long 0xFE00, 0xFE0F
    .long 0xFE20, 0xFE2F
    .long 0xFEFF, 0xFEFF
    .long 0x101FD, 0x101FD
    .long 0x102E0, 0x102E0
    .long 0x10376, 0x1037A
    .long 0x10A01, 0x10A0F
    .long 0x10A38, 0x10A3F
    .long 0x11000, 0x11002
    .long 0x11038, 0x11046
    .long 0x1107F, 0x11082
    .long 0x110B0, 0x110BA
    .long 0x11100, 0x11102
    .long 0x11127, 0x11134
    .long 0x11173, 0x11173
    .long 0x11180, 0x11182
    .long 0x111B3, 0x111C0
    .long 0x1122C, 0x11237
    .long 0x112DF, 0x112EA
    .long 0x11300, 0x11303
    .long 0x1133C, 0x1133C
    .long 0x1133E, 0x11344
    .long 0x11347, 0x11348
    .long 0x1134B, 0x1134D
    .long 0x11357, 0x11357
    .long 0x11362, 0x11363
    .long 0x114B0, 0x114C3
    .long 0x115AF, 0x115B5
    .long 0x115B8, 0x115C0
    .long 0x11630, 0x11640
    .long 0x116AB, 0x116B7
    .long 0x1171D, 0x1172B
    .long 0x16AF0, 0x16AF4
    .long 0x16B30, 0x16B36
    .long 0x16F51, 0x16F7E
    .long 0x16F8F, 0x16F92
    .long 0x1BC9D, 0x1BC9E
    .long 0x1D165, 0x1D169
    .long 0x1D16D, 0x1D182
    .long 0x1D185, 0x1D18B
    .long 0x1D1AA, 0x1D1AD
    .long 0x1D242, 0x1D244
    .long 0x1DA00, 0x1DA36
    .long 0x1DA3B, 0x1DA6C
    .long 0x1DA75, 0x1DA75
    .long 0x1DA84, 0x1DA84
    .long 0x1DA9B, 0x1DA9F
    .long 0x1DAA1, 0x1DAAF
    .long 0x1E8D0, 0x1E8D6
    .long 0x1E944, 0x1E94A
    .long 0xE0100, 0xE01EF
    .long -1

# Wide / double-width codepoints. Pair table ending in -1.
.p2align 3
.Lwc_wide_ranges:
    .long 0x1100, 0x115F
    .long 0x2329, 0x232A
    .long 0x2E80, 0x303E
    .long 0x3041, 0x33FF
    .long 0x3400, 0x4DBF
    .long 0x4E00, 0x9FFF
    .long 0xA000, 0xA4CF
    .long 0xA960, 0xA97F
    .long 0xAC00, 0xD7A3
    .long 0xF900, 0xFAFF
    .long 0xFE10, 0xFE19
    .long 0xFE30, 0xFE6F
    .long 0xFF00, 0xFF60
    .long 0xFFE0, 0xFFE6
    .long 0x1B000, 0x1B001
    .long 0x1F000, 0x1F2FF
    .long 0x1F300, 0x1F64F
    .long 0x1F680, 0x1F6FF
    .long 0x1F7E0, 0x1F7EB
    .long 0x1F7F0, 0x1F7F0
    .long 0x1F900, 0x1F9FF
    .long 0x1FA70, 0x1FAFF
    .long 0x20000, 0x2FFFD
    .long 0x30000, 0x3FFFD
    .long -1
