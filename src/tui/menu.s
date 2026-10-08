# opcode tui: slash-command menu state machine, built-in command table and
# renderer.
#
#   menu_init()                    zero the module state
#   menu_update(ptr, len)          recompute open/filter/entries
#   menu_open() -> eax 1|0
#   menu_count() -> eax
#   menu_sel() -> eax
#   menu_top() -> eax              clamped so the selection is visible
#   menu_height(esi avail) -> eax  min(count, 8, avail); 0 when closed
#   menu_key(esi key, edx cp, ecx mods) -> eax 1 consumed | 0
#   menu_render(rdi grid, esi x, edx y, ecx w, r8d maxrows) -> eax 0
#   menu_name(edi index) -> rax ptr, rdx len
#   menu_desc(edi index) -> rax ptr, rdx len
#   menu_size                      sizeof state, for the caller's zeroed buffer
#
# The menu is chrome on the terminal background: the selected row is only
# reverse-video, never a themed background band.  Entries are the built-in
# slash commands; the filter is the bytes typed after a leading `/` and there
# is no argument phase (a space/tab/newline closes the menu).
#
# State is module-local; the public entry points mirror the frozen API.

.include "opcode.inc"
.include "tui/theme.inc"

# ---------------------------------------------------------------- key codes
# Distinct local names: editor.s defines its own K_* with the same values.
.equ .LK_UP,    0x110001
.equ .LK_DOWN,  0x110002
.equ .LK_PGUP,  0x110007
.equ .LK_PGDN,  0x110008
.equ .LK_TAB,   0x09
.equ .LK_ENTER, 0x0a
.equ .LK_ESC,   0x1b
.equ .LK_BACKSPACE, 0x7f

# Cell attribute bits (render.s keeps its own copies).
.equ .LA_DIM,      4
.equ .LA_REVERSE,  8

.equ MENU_STORE_MAX,   32
.equ MENU_VISIBLE_MAX, 8
.equ MENU_FILTER_MAX,  63
.equ MENU_BUILTIN_N,   8
.equ MENU_SRC_MAX,     MENU_STORE_MAX

# Picker kinds.  COMMAND is the slash-command menu (text driven); MODEL and
# THINKING are modal pickers whose rows are supplied by the app; PICK is the
# standalone pre-TUI list used by the session picker.
.equ MENU_KIND_COMMAND,  0
.equ MENU_KIND_MODEL,    1
.equ MENU_KIND_THINKING, 2
.equ MENU_KIND_PICK,     3

# Module state.  M_name/M_desc hold pointers into the builtin table so the
# filtered order is cheap to reconstruct on every update.
STRUCT
F M_open,       4
F M_dismissed,  4
F M_sel,        4
F M_top,        4
F M_count,      4
F M_flen,       4
F M_kind,       4
F M_filter,    64
F M_name,     256
F M_desc,     256
# Explicit rows for the modal kinds (MODEL/THINKING/PICK): the full unfiltered
# list, from which M_name/M_desc hold the filtered view.
F M_all_count,  4
F M_all_name, 256
F M_all_desc, 256
ENDSTRUCT M_SIZE

# menu_render locals, addressed relative to rbp (frame leaves room to -144).
.set MR_i,     -56
.set MR_nx,    -144
.set MR_cnt,   -64
.set MR_top,   -72
.set MR_r,     -80
.set MR_namew, -88
.set MR_attrs, -96
.set MR_yy,    -104
.set MR_col,   -112
.set MR_nptr,  -120
.set MR_nlen,  -128
.set MR_rem,   -132
.set MR_fg,    -136
.set MR_muted, -140

# Builtin command table (name, description), in menu order.  Descriptions are
# CSTRs, matching menu_desc's contract.
.section .rodata
.p2align 3
.Lmn_clear: .asciz "clear"
.Lmn_help:  .asciz "help"
.Lmn_model: .asciz "model"
.Lmn_new:   .asciz "new"
.Lmn_quit:  .asciz "quit"
.Lmn_theme: .asciz "theme"
.Lmn_thinking: .asciz "thinking"
.Lmn_compact:  .asciz "compact"

.Lmd_clear: .asciz "clear the transcript view"
.Lmd_help:  .asciz "show key bindings and slash commands"
.Lmd_model: .asciz "switch model (no argument reports it)"
.Lmd_new:   .asciz "clear the transcript view and start a new session"
.Lmd_quit:  .asciz "exit opcode"
.Lmd_theme: .asciz "switch theme (dark|light|<name>)"
.Lmd_thinking: .asciz "set reasoning level (off|low|medium|high)"
.Lmd_compact:  .asciz "compact the conversation into a summary"

.p2align 3
.Lmenu_builtin:
    .quad .Lmn_clear, .Lmd_clear
    .quad .Lmn_help,  .Lmd_help
    .quad .Lmn_model, .Lmd_model
    .quad .Lmn_new,   .Lmd_new
    .quad .Lmn_quit,  .Lmd_quit
    .quad .Lmn_theme, .Lmd_theme
    .quad .Lmn_thinking, .Lmd_thinking
    .quad .Lmn_compact,  .Lmd_compact

.Lmenu_skill_prefix: .asciz "skill:"

.data
.p2align 3
.globl menu_size
GTYPE menu_size, @object
menu_size: .quad M_SIZE

.bss
.p2align 4
.Lmenu_state: .zero M_SIZE
# Captured command sources: built-ins, then prompt templates, then skills (as
# "skill:<name>") and, when a registry exists, extension commands.  Refreshed
# once at startup so menu_update never touches the filesystem.
.p2align 4
.Lmenu_src_name: .zero 8 * MENU_SRC_MAX
.Lmenu_src_desc: .zero 8 * MENU_SRC_MAX
.Lmenu_src_count: .zero 4
.Lmenu_bump:     .zero 8
.Lmenu_src_text: .zero 64 * MENU_SRC_MAX

.text

# ---------------------------------------------------------------- helpers
# .Lmenu_strlen(rdi=cstr) -> rax = bytes before NUL.  Clobbers rax/rdi only, so
# callers may keep loop state in the callee-saved registers.
.Lmenu_strlen:
    xor eax, eax
1:  cmp byte ptr [rdi + rax], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

# .Lmenu_prefix(rdi=name cstr, rsi=filter, edx=flen) -> eax 1|0.  Case-sensitive
# byte prefix match (names are ASCII).
.Lmenu_prefix:
    xor ecx, ecx
1:  cmp ecx, edx
    jae 2f
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne 3f
    inc ecx
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# .Lmenu_substr_ci(rdi=name cstr, rsi=filter, edx=flen) -> eax 1|0.
# Case-insensitive ASCII substring match: the filter may appear anywhere in the
# name, so "opus" finds "claude-opus-4-5".  An empty filter matches everything.
.Lmenu_substr_ci:
    test edx, edx
    jz .Lmsc_yes
    xor r10d, r10d               # name start offset
.Lmsc_outer:
    mov al, [rdi + r10]
    test al, al
    jz .Lmsc_no
    mov r8, r10                  # name cursor
    xor ecx, ecx                 # filter offset
.Lmsc_inner:
    cmp ecx, edx
    jae .Lmsc_yes
    mov al, [rdi + r8]
    test al, al
    jz .Lmsc_no
    mov r9b, [rsi + rcx]
    cmp al, 'A'
    jb 1f
    cmp al, 'Z'
    ja 1f
    add al, 0x20
1:  cmp r9b, 'A'
    jb 2f
    cmp r9b, 'Z'
    ja 2f
    add r9b, 0x20
2:  cmp al, r9b
    jne .Lmsc_next
    inc r8
    inc ecx
    jmp .Lmsc_inner
.Lmsc_next:
    inc r10d
    jmp .Lmsc_outer
.Lmsc_yes:
    mov eax, 1
    ret
.Lmsc_no:
    xor eax, eax
    ret

# .Lmenu_streq(rdi, rsi) -> eax 1|0.
.Lmenu_streq:
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# menu_is_builtin(rdi=name) -> eax 1|0.
menu_is_builtin:
    PROLOGUE 0
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13d, MENU_BUILTIN_N
    jae 2f
    lea rax, [rip + .Lmenu_builtin]
    mov rcx, r13
    shl rcx, 4
    mov rdi, [rax + rcx]
    mov rsi, r12
    call .Lmenu_streq
    test eax, eax
    jnz 3f
    inc r13d
    jmp 1b
2:  xor eax, eax
    EPILOGUE
3:  mov eax, 1
    EPILOGUE

# menu_is_reserved(rdi=name) -> eax 1 when the name starts with "skill:".
menu_is_reserved:
    mov al, [rdi]
    cmp al, 's'
    jne 1f
    mov al, [rdi + 1]
    cmp al, 'k'
    jne 1f
    mov al, [rdi + 2]
    cmp al, 'i'
    jne 1f
    mov al, [rdi + 3]
    cmp al, 'l'
    jne 1f
    mov al, [rdi + 4]
    cmp al, 'l'
    jne 1f
    mov al, [rdi + 5]
    cmp al, ':'
    jne 1f
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# menu_copy_name(rdi=cstr) -> rax pointer into the bump arena (NUL terminated).
menu_copy_name:
    PROLOGUE 0
    mov rbx, [rip + .Lmenu_bump]
    mov r12, rbx
    xor ecx, ecx
1:  mov al, [rdi + rcx]
    test al, al
    jz 2f
    cmp ecx, 63
    jae 2f
    mov [r12 + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [r12 + rcx], 0
    lea rax, [r12 + rcx + 1]
    mov [rip + .Lmenu_bump], rax
    mov rax, r12
    EPILOGUE

# menu_copy_skill(rdi=skill name) -> rax "skill:<name>" in the bump arena.
menu_copy_skill:
    PROLOGUE 0
    mov r12, [rip + .Lmenu_bump]
    mov dword ptr [r12], 0x6c696b73      # "skil"
    mov word ptr [r12 + 4], 0x3a6c       # "l:"
    xor ecx, ecx
1:  mov al, [rdi + rcx]
    test al, al
    jz 2f
    cmp ecx, 56
    jae 2f
    mov [r12 + 6 + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [r12 + 6 + rcx], 0
    lea rax, [r12 + 6 + rcx + 1]
    mov [rip + .Lmenu_bump], rax
    mov rax, r12
    EPILOGUE

# menu_src_has(rdi=name, esi=count) -> eax 1|0 when the captured list holds it.
menu_src_has:
    PROLOGUE 0
    mov r12, rdi
    mov r13d, esi
    xor ebx, ebx
1:  cmp ebx, r13d
    jae 2f
    lea rax, [rip + .Lmenu_src_name]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz 3f
    mov rsi, r12
    call .Lmenu_streq
    test eax, eax
    jnz 4f
3:  inc ebx
    jmp 1b
2:  xor eax, eax
    EPILOGUE
4:  mov eax, 1
    EPILOGUE

# ---------------------------------------------------------------- lifecycle
# menu_init(): zero the filter state, then capture the command sources.  The
# capture calls prompt_templates_init() and skills_list() once, so skill_body
# later finds the same table the menu advertised.
FN menu_init
    PROLOGUE 0
    lea rdi, [rip + .Lmenu_state]
    xor esi, esi
    mov edx, M_SIZE
    call memset
    call menu_sources_refresh
    EPILOGUE

# menu_sources_refresh(): rebuild the captured source list (built-ins, prompt
# templates, skills, extension commands).  Module-local; invoked by menu_init.
FN menu_sources_refresh
    PROLOGUE 0
    lea rax, [rip + .Lmenu_src_text]
    mov [rip + .Lmenu_bump], rax
    xor ebx, ebx                  # src count
    xor r12d, r12d
.Lmsr_builtin:
    cmp r12d, MENU_BUILTIN_N
    jae .Lmsr_prompts
    lea rax, [rip + .Lmenu_builtin]
    mov rcx, r12
    shl rcx, 4
    add rax, rcx
    mov rdx, [rax]
    mov rcx, [rax + 8]
    lea rax, [rip + .Lmenu_src_name]
    mov [rax + rbx*8], rdx
    lea rax, [rip + .Lmenu_src_desc]
    mov [rax + rbx*8], rcx
    inc ebx
    inc r12d
    jmp .Lmsr_builtin
.Lmsr_prompts:
    call prompt_templates_init
    call prompt_templates_count
    mov r12d, eax
    xor r13d, r13d
.Lmsr_prompt:
    cmp r13d, r12d
    jae .Lmsr_skills
    cmp ebx, MENU_SRC_MAX
    jae .Lmsr_done
    mov edi, r13d
    call prompt_templates_at
    test rax, rax
    jz .Lmsr_prompt_next
    mov r14, rax
    mov rdi, r14
    call menu_is_builtin
    test eax, eax
    jnz .Lmsr_prompt_next
    mov rdi, r14
    call menu_is_reserved
    test eax, eax
    jnz .Lmsr_prompt_next
    mov rdi, r14
    call menu_copy_name
    lea rcx, [rip + .Lmenu_src_name]
    mov [rcx + rbx*8], rax
    lea rcx, [rip + .Lmenu_src_desc]
    mov qword ptr [rcx + rbx*8], 0
    inc ebx
.Lmsr_prompt_next:
    inc r13d
    jmp .Lmsr_prompt
.Lmsr_skills:
    call skills_list
    mov r12d, eax
    xor r13d, r13d
.Lmsr_skill:
    cmp r13d, r12d
    jae .Lmsr_ext
    cmp ebx, MENU_SRC_MAX
    jae .Lmsr_done
    mov edi, r13d
    call skills_at
    test rax, rax
    jz .Lmsr_skill_next
    mov rdi, rax
    call menu_copy_skill
    lea rcx, [rip + .Lmenu_src_name]
    mov [rcx + rbx*8], rax
    lea rcx, [rip + .Lmenu_src_desc]
    mov qword ptr [rcx + rbx*8], 0
    inc ebx
.Lmsr_skill_next:
    inc r13d
    jmp .Lmsr_skill
.Lmsr_ext:
    cmp ebx, MENU_SRC_MAX
    jae .Lmsr_done
    mov eax, [rip + opcode_host_command_count]
    test eax, eax
    jz .Lmsr_done
    xor r13d, r13d
.Lmsr_ext_loop:
    cmp r13d, [rip + opcode_host_command_count]
    jae .Lmsr_done
    cmp ebx, MENU_SRC_MAX
    jae .Lmsr_done
    lea rax, [rip + opcode_host_commands]
    mov rcx, r13
    imul rcx, rcx, 24
    add rax, rcx
    mov rdi, [rax]
    test rdi, rdi
    jz .Lmsr_ext_next
    mov r14, [rax + 8]
    mov r15, [rax]
    call menu_is_builtin
    test eax, eax
    jnz .Lmsr_ext_next
    mov rdi, r15
    call menu_is_reserved
    test eax, eax
    jnz .Lmsr_ext_next
    mov rdi, r15
    mov esi, ebx
    call menu_src_has
    test eax, eax
    jnz .Lmsr_ext_next
    mov rdi, r15
    call menu_copy_name
    lea rcx, [rip + .Lmenu_src_name]
    mov [rcx + rbx*8], rax
    lea rcx, [rip + .Lmenu_src_desc]
    mov [rcx + rbx*8], r14
    inc ebx
.Lmsr_ext_next:
    inc r13d
    jmp .Lmsr_ext_loop
.Lmsr_done:
    mov [rip + .Lmenu_src_count], ebx
    EPILOGUE

# ---------------------------------------------------------------- picker modes
# menu_begin(esi=kind): select the picker kind and reset the modal state.  A
# COMMAND begin hands control back to menu_update; MODEL/THINKING/PICK wait for
# menu_rows to load their entries.
FN menu_begin
    mov [rip + .Lmenu_state + M_kind], esi
    mov dword ptr [rip + .Lmenu_state + M_open], 0
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 0
    mov dword ptr [rip + .Lmenu_state + M_flen], 0
    mov dword ptr [rip + .Lmenu_state + M_filter], 0
    mov dword ptr [rip + .Lmenu_state + M_count], 0
    mov dword ptr [rip + .Lmenu_state + M_sel], 0
    mov dword ptr [rip + .Lmenu_state + M_top], 0
    mov dword ptr [rip + .Lmenu_state + M_all_count], 0
    xor eax, eax
    ret

# menu_close(): dismiss the modal picker and return to COMMAND so the next
# `/word` in the composer opens the command menu again.
FN menu_close
    mov dword ptr [rip + .Lmenu_state + M_open], 0
    mov dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    xor eax, eax
    ret

# menu_kind() -> eax MENU_KIND_*
FN menu_kind
    mov eax, [rip + .Lmenu_state + M_kind]
    ret

# menu_is_modal() -> eax 1 when a non-COMMAND picker is open.
FN menu_is_modal
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    je 1f
    mov eax, [rip + .Lmenu_state + M_open]
    ret
1:  xor eax, eax
    ret

# menu_rows(rdi=names char**,  rsi=descs char**, edx=n, ecx=initial): load the
# explicit rows for the current modal kind and rebuild the filtered view.  The
# pointer arrays are copied; the strings stay caller-owned.
FN menu_rows
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r13d, r13d
    jns 1f
    xor r13d, r13d
1:  cmp r13d, MENU_STORE_MAX
    jbe 2f
    mov r13d, MENU_STORE_MAX
2:  mov [rip + .Lmenu_state + M_all_count], r13d
    xor r14d, r14d
3:  cmp r14d, r13d
    jae 4f
    lea rax, [rip + .Lmenu_state + M_all_name]
    mov rdx, [rbx + r14*8]
    mov [rax + r14*8], rdx
    lea rax, [rip + .Lmenu_state + M_all_desc]
    mov rdx, [r12 + r14*8]
    mov [rax + r14*8], rdx
    inc r14d
    jmp 3b
4:  mov dword ptr [rip + .Lmenu_state + M_flen], 0
    mov dword ptr [rip + .Lmenu_state + M_filter], 0
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 0
    mov eax, ecx
    test eax, eax
    jns 5f
    xor eax, eax
5:  mov [rip + .Lmenu_state + M_sel], eax
    mov dword ptr [rip + .Lmenu_state + M_top], 0
    call .Lmu_build
    xor eax, eax
    EPILOGUE

# menu_update(rdi=text, rsi=len): recompute open/filter/entries.  A non-menu
# word closes the menu but deliberately leaves the last filter in place so that
# backing a character out re-opens the same word without resetting the
# selection or an Escape dismissal.
FN menu_update
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne .Lmu_noop
    PROLOGUE 0
    mov rbx, rdi                   # text
    mov r12, rsi                   # len
    test r12, r12
    jz .Lmu_close
    cmp byte ptr [rbx], '/'
    jne .Lmu_close

    # Scan for a terminator: the word after '/' must run to end of text.
    mov rcx, 1
.Lmu_scan:
    cmp rcx, r12
    jae .Lmu_nosc
    movzx eax, byte ptr [rbx + rcx]
    cmp eax, ' '
    je .Lmu_close
    cmp eax, 0x09
    je .Lmu_close
    cmp eax, 0x0a
    je .Lmu_close
    inc rcx
    jmp .Lmu_scan

.Lmu_nosc:
    mov r13, r12
    dec r13                        # filter length
    cmp r13, MENU_FILTER_MAX
    ja .Lmu_close

    # A changed filter resets selection and dismissal.
    cmp r13d, [rip + .Lmenu_state + M_flen]
    jne .Lmu_changed
    test r13, r13
    jz .Lmu_build_call
    lea rdi, [rip + .Lmenu_state + M_filter]
    lea rsi, [rbx + 1]
    mov rdx, r13
    call memeq
    test eax, eax
    jz .Lmu_changed
    jmp .Lmu_build_call

.Lmu_changed:
    mov [rip + .Lmenu_state + M_flen], r13d
    lea rdi, [rip + .Lmenu_state + M_filter]
    lea rsi, [rbx + 1]
    mov rdx, r13
    call memcpy
    mov byte ptr [rax + r13], 0    # NUL-terminate for debuggability
    mov dword ptr [rip + .Lmenu_state + M_sel], 0
    mov dword ptr [rip + .Lmenu_state + M_top], 0
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 0

.Lmu_build_call:
    call .Lmu_build
    xor eax, eax
    EPILOGUE

.Lmu_close:
    mov dword ptr [rip + .Lmenu_state + M_open], 0
    # Clear the dismissal so an Esc that closed the menu never permanently
    # suppresses reopening the same word.  The remembered filter is cleared
    # too, so a later re-open of the same word starts from a clean slate.
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 0
    mov dword ptr [rip + .Lmenu_state + M_flen], 0
    xor eax, eax
    EPILOGUE

.Lmu_noop:
    xor eax, eax
    ret

# .Lmu_build(): rebuild the filtered row pointers for the active kind.
#   COMMAND -> .Lmenu_src_* filtered case-sensitively
#   else    -> M_all_* filtered case-insensitively
# Preserves r12-r15 (uses r13/r14 internally); returns no value.
.Lmu_build:
    push r13
    push r14
    push r15                       # pad to keep the stack 16-byte aligned
    xor r13d, r13d                 # filtered count
    xor r14d, r14d                 # source index
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne .Lmu_explicit
.Lmu_loop:
    cmp r14d, [rip + .Lmenu_src_count]
    jae .Lmu_built
    lea rax, [rip + .Lmenu_src_name]
    mov rdi, [rax + r14*8]
    test rdi, rdi
    jz .Lmu_next
    lea rsi, [rip + .Lmenu_state + M_filter]
    mov edx, [rip + .Lmenu_state + M_flen]
    call .Lmenu_prefix
    test eax, eax
    jz .Lmu_next
    cmp r13d, MENU_STORE_MAX
    jae .Lmu_next
    lea rax, [rip + .Lmenu_state + M_name]
    lea rcx, [rip + .Lmenu_src_name]
    mov rdx, [rcx + r14*8]
    mov [rax + r13*8], rdx
    lea rax, [rip + .Lmenu_state + M_desc]
    lea rcx, [rip + .Lmenu_src_desc]
    mov rdx, [rcx + r14*8]
    mov [rax + r13*8], rdx
    inc r13d
.Lmu_next:
    inc r14d
    jmp .Lmu_loop
.Lmu_explicit:
    cmp r14d, [rip + .Lmenu_state + M_all_count]
    jae .Lmu_built
    lea rax, [rip + .Lmenu_state + M_all_name]
    mov rdi, [rax + r14*8]
    test rdi, rdi
    jz .Lmu_enext
    lea rsi, [rip + .Lmenu_state + M_filter]
    mov edx, [rip + .Lmenu_state + M_flen]
    call .Lmenu_substr_ci
    test eax, eax
    jz .Lmu_enext
    cmp r13d, MENU_STORE_MAX
    jae .Lmu_enext
    lea rax, [rip + .Lmenu_state + M_name]
    lea rcx, [rip + .Lmenu_state + M_all_name]
    mov rdx, [rcx + r14*8]
    mov [rax + r13*8], rdx
    lea rax, [rip + .Lmenu_state + M_desc]
    lea rcx, [rip + .Lmenu_state + M_all_desc]
    mov rdx, [rcx + r14*8]
    mov [rax + r13*8], rdx
    inc r13d
.Lmu_enext:
    inc r14d
    jmp .Lmu_explicit
.Lmu_built:
    mov [rip + .Lmenu_state + M_count], r13d

    # Clamp the selection into range.
    mov eax, [rip + .Lmenu_state + M_sel]
    cmp eax, r13d
    jb .Lmu_selok
    test r13d, r13d
    jz .Lmu_selzero
    mov eax, r13d
    dec eax
    mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmu_selok
.Lmu_selzero:
    mov dword ptr [rip + .Lmenu_state + M_sel], 0
.Lmu_selok:
    xor eax, eax
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne .Lmu_open_modal
    test r13d, r13d
    jz .Lmu_setopen
    cmp dword ptr [rip + .Lmenu_state + M_dismissed], 0
    setz al
    jmp .Lmu_setopen
.Lmu_open_modal:
    # A modal picker stays open while it has rows even when the filter
    # matches nothing, so typing can keep narrowing without dropping the
    # keystrokes back into the composer.
    cmp dword ptr [rip + .Lmenu_state + M_all_count], 0
    jz .Lmu_setopen
    cmp dword ptr [rip + .Lmenu_state + M_dismissed], 0
    setz al
.Lmu_setopen:
    mov [rip + .Lmenu_state + M_open], eax
    pop r15
    pop r14
    pop r13
    ret

# ---------------------------------------------------------------- accessors
FN menu_open
    mov eax, [rip + .Lmenu_state + M_open]
    ret

FN menu_count
    mov eax, [rip + .Lmenu_state + M_count]
    ret

FN menu_sel
    mov eax, [rip + .Lmenu_state + M_sel]
    ret

# menu_top(): stored top clamped so the selection sits in the 8-row window.
# menu_render narrows this further for the actual row budget.
FN menu_top
    mov eax, [rip + .Lmenu_state + M_top]
    mov ecx, [rip + .Lmenu_state + M_sel]
    test eax, eax
    jns 1f
    xor eax, eax
1:  cmp eax, ecx
    jle 2f
    mov eax, ecx                   # top above the selection -> pull it down
2:  mov edx, eax
    add edx, MENU_VISIBLE_MAX
    cmp ecx, edx
    jl 3f
    mov eax, ecx
    sub eax, MENU_VISIBLE_MAX - 1  # selection below the window -> scroll
3:  test eax, eax
    jns 4f
    xor eax, eax
4:  ret

# menu_height(esi=avail) -> min(count, 8, avail); 0 when closed or no room.
FN menu_height
    cmp dword ptr [rip + .Lmenu_state + M_open], 0
    je 9f
    mov ecx, [rip + .Lmenu_state + M_count]
    test ecx, ecx
    jle 9f
    test esi, esi
    jle 9f
    mov eax, ecx
    cmp eax, MENU_VISIBLE_MAX
    jbe 1f
    mov eax, MENU_VISIBLE_MAX
1:  cmp eax, esi
    jbe 2f
    mov eax, esi
2:  ret
9:  xor eax, eax
    ret

# menu_key(esi=key, edx=cp, ecx=mods) -> 1 consumed | 0.  Only navigation and
# dismissal are consumed here; the shell reads menu_name(menu_sel()) itself to
# complete or dispatch on Tab/Enter.
FN menu_key
    cmp dword ptr [rip + .Lmenu_state + M_open], 0
    je .Lmk_no
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne .Lmk_modal
    cmp esi, .LK_UP
    je .Lmk_up
    cmp esi, .LK_DOWN
    je .Lmk_down
    cmp esi, .LK_TAB
    je .Lmk_yes
    cmp esi, .LK_ENTER
    je .Lmk_enter
    cmp esi, .LK_ESC
    je .Lmk_esc
.Lmk_no:
    xor eax, eax
    ret
.Lmk_up:
    mov eax, [rip + .Lmenu_state + M_sel]
    test eax, eax
    jle .Lmk_yes
    dec eax
    mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmk_down:
    mov eax, [rip + .Lmenu_state + M_sel]
    inc eax
    cmp eax, [rip + .Lmenu_state + M_count]
    jge .Lmk_yes
    mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmk_enter:
    test ecx, 1                    # Alt+Enter inserts a newline instead
    jnz .Lmk_no
.Lmk_yes:
    mov eax, 1
    ret
.Lmk_esc:
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 1
    mov dword ptr [rip + .Lmenu_state + M_open], 0
    mov eax, 1
    ret

# ---- modal picker keys ----------------------------------------------------
# MODEL/THINKING/PICK: printable input edits the filter, Backspace deletes,
# Up/Down/PageUp/PageDown move, Enter is consumed so the shell can apply the
# selection, Esc closes and returns to COMMAND.
.Lmk_modal:
    cmp esi, .LK_UP
    je .Lmkm_up
    cmp esi, .LK_DOWN
    je .Lmkm_down
    cmp esi, .LK_PGUP
    je .Lmkm_pgup
    cmp esi, .LK_PGDN
    je .Lmkm_pgdn
    cmp esi, .LK_ESC
    je .Lmkm_esc
    cmp esi, .LK_BACKSPACE
    je .Lmkm_back
    cmp esi, .LK_ENTER
    je .Lmk_yes
    cmp edx, 0x20
    jb .Lmk_no
    cmp edx, 0x7f
    je .Lmk_no
    jmp .Lmkm_filter
.Lmkm_up:
    mov eax, [rip + .Lmenu_state + M_sel]
    test eax, eax
    jle .Lmk_yes
    dec eax
    mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmkm_down:
    mov eax, [rip + .Lmenu_state + M_sel]
    inc eax
    cmp eax, [rip + .Lmenu_state + M_count]
    jge .Lmk_yes
    mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmkm_pgup:
    mov eax, [rip + .Lmenu_state + M_sel]
    sub eax, MENU_VISIBLE_MAX
    jns 1f
    xor eax, eax
1:  mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmkm_pgdn:
    mov eax, [rip + .Lmenu_state + M_sel]
    add eax, MENU_VISIBLE_MAX
    mov ecx, [rip + .Lmenu_state + M_count]
    dec ecx
    js 1f
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  mov [rip + .Lmenu_state + M_sel], eax
    jmp .Lmk_yes
.Lmkm_esc:
    mov dword ptr [rip + .Lmenu_state + M_dismissed], 1
    mov dword ptr [rip + .Lmenu_state + M_open], 0
    mov dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    mov eax, 1
    ret
.Lmkm_back:
    mov eax, [rip + .Lmenu_state + M_flen]
    test eax, eax
    jz .Lmk_yes
    dec eax
    mov [rip + .Lmenu_state + M_flen], eax
    lea rcx, [rip + .Lmenu_state + M_filter]
    mov byte ptr [rcx + rax], 0
    sub rsp, 8
    call .Lmu_build
    add rsp, 8
    jmp .Lmk_yes
.Lmkm_filter:
    mov eax, [rip + .Lmenu_state + M_flen]
    cmp eax, MENU_FILTER_MAX
    jae .Lmk_yes
    lea rcx, [rip + .Lmenu_state + M_filter]
    mov [rcx + rax], dl
    inc eax
    mov [rip + .Lmenu_state + M_flen], eax
    mov byte ptr [rcx + rax], 0
    sub rsp, 8
    call .Lmu_build
    add rsp, 8
    jmp .Lmk_yes

# menu_name(edi=index) -> rax ptr, rdx len (0,0 when out of range).
FN menu_name
    PROLOGUE 0
    mov eax, edi
    test eax, eax
    js .Lmnn_none
    cmp eax, [rip + .Lmenu_state + M_count]
    jae .Lmnn_none
    lea rcx, [rip + .Lmenu_state + M_name]
    mov rbx, [rcx + rax*8]
    mov rdi, rbx
    call .Lmenu_strlen
    mov rdx, rax
    mov rax, rbx
    EPILOGUE
.Lmnn_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# menu_desc(edi=index) -> rax ptr, rdx len (0,0 when out of range).
FN menu_desc
    PROLOGUE 0
    mov eax, edi
    test eax, eax
    js .Lmnd_none
    cmp eax, [rip + .Lmenu_state + M_count]
    jae .Lmnd_none
    lea rcx, [rip + .Lmenu_state + M_desc]
    mov rbx, [rcx + rax*8]
    test rbx, rbx
    jz .Lmnd_none
    mov rdi, rbx
    call .Lmenu_strlen
    mov rdx, rax
    mov rax, rbx
    EPILOGUE
.Lmnd_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# ---------------------------------------------------------------- renderer
# menu_render(grid, x, y, w, maxrows): draw the visible window of entries.
# `/name` starts at x; the description starts two columns after the widest name
# and is dim+muted unless the row is selected.  Both fields are clipped at x+w
# and never wrap.
FN menu_render
    PROLOGUE 96
    mov rbx, rdi                   # grid
    mov r12d, esi                  # x
    mov r13d, edx                  # y
    mov r14d, ecx                  # w
    mov r15d, r8d                  # maxrows
    cmp dword ptr [rip + .Lmenu_state + M_open], 0
    je .Lmr_zero
    test r14d, r14d
    jle .Lmr_zero
    test r15d, r15d
    jle .Lmr_zero
    mov eax, [rip + .Lmenu_state + M_count]
    test eax, eax
    jle .Lmr_zero
    mov [rbp + MR_cnt], eax
    mov esi, TH_FG
    call theme_rgb
    mov [rbp + MR_fg], eax
    mov esi, TH_MUTED
    call theme_rgb
    mov [rbp + MR_muted], eax

    # Widest name over every stored entry, capped to w-1.
    mov dword ptr [rbp + MR_namew], 0
    mov dword ptr [rbp + MR_i], 0
.Lmr_wloop:
    mov eax, [rbp + MR_i]
    cmp eax, [rbp + MR_cnt]
    jae .Lmr_wdone
    lea rcx, [rip + .Lmenu_state + M_name]
    mov rdi, [rcx + rax*8]
    call .Lmenu_strlen
    cmp eax, [rbp + MR_namew]
    jbe .Lmr_wnext
    mov [rbp + MR_namew], eax
.Lmr_wnext:
    inc dword ptr [rbp + MR_i]
    jmp .Lmr_wloop
.Lmr_wdone:
    mov eax, [rbp + MR_namew]
    mov ecx, r14d
    dec ecx
    cmp eax, ecx
    jbe 1f
    mov eax, ecx
1:  mov [rbp + MR_namew], eax

    # Start from menu_top(), then guarantee the selection fits maxrows.
    call menu_top
    mov ecx, [rip + .Lmenu_state + M_sel]
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  mov edx, eax
    add edx, r15d
    cmp ecx, edx
    jl 2f
    mov eax, ecx
    sub eax, r15d
    inc eax
2:  test eax, eax
    jns 3f
    xor eax, eax
3:  mov [rbp + MR_top], eax

    mov dword ptr [rbp + MR_r], 0
.Lmr_row:
    mov r8d, [rbp + MR_r]
    cmp r8d, r15d
    jae .Lmr_zero
    add r8d, [rbp + MR_top]
    cmp r8d, [rbp + MR_cnt]
    jae .Lmr_zero
    mov [rbp + MR_i], r8d
    mov r9d, r13d
    add r9d, [rbp + MR_r]
    mov [rbp + MR_yy], r9d
    xor r10d, r10d
    cmp r8d, [rip + .Lmenu_state + M_sel]
    jne 1f
    mov r10d, .LA_REVERSE
1:  mov [rbp + MR_attrs], r10d

    # Command rows render "/name"; the modal pickers render "name".
    mov [rbp + MR_nx], r12d
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne .Lmr_noslash
    mov rdi, rbx
    mov esi, r12d
    mov edx, [rbp + MR_yy]
    mov ecx, 0x2F
    mov r8d, [rbp + MR_fg]
    xor r9d, r9d
    sub rsp, 16
    mov eax, [rbp + MR_attrs]
    mov [rsp], rax
    call grid_put
    add rsp, 16
    inc dword ptr [rbp + MR_nx]
.Lmr_noslash:
    # Name at MR_nx, clipped to the row width (w-1 for the slash + name).
    mov eax, r14d
    cmp dword ptr [rip + .Lmenu_state + M_kind], MENU_KIND_COMMAND
    jne 1f
    dec eax
1:  test eax, eax
    jle .Lmr_desc
    mov [rbp + MR_col], eax
    lea rcx, [rip + .Lmenu_state + M_name]
    mov edx, [rbp + MR_i]
    mov rdi, [rcx + rdx*8]
    mov [rbp + MR_nptr], rdi
    call .Lmenu_strlen
    cmp eax, [rbp + MR_col]
    jbe 2f
    mov eax, [rbp + MR_col]
2:  mov [rbp + MR_nlen], eax
    mov rdi, rbx
    mov esi, [rbp + MR_nx]
    mov edx, [rbp + MR_yy]
    mov ecx, [rbp + MR_fg]
    xor r8d, r8d
    mov r9d, [rbp + MR_attrs]
    sub rsp, 16
    mov rax, [rbp + MR_nptr]
    mov [rsp], rax
    mov eax, [rbp + MR_nlen]
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16

.Lmr_desc:
    # Description column = x + namew + 2; skip when it would start past x+w.
    mov r11d, r12d
    add r11d, [rbp + MR_namew]
    add r11d, 2
    mov [rbp + MR_col], r11d
    mov edx, r12d
    add edx, r14d
    cmp r11d, edx
    jge .Lmr_next
    sub edx, r11d
    mov [rbp + MR_rem], edx
    lea rcx, [rip + .Lmenu_state + M_desc]
    mov eax, [rbp + MR_i]
    mov rdi, [rcx + rax*8]
    test rdi, rdi
    jz .Lmr_next
    mov [rbp + MR_nptr], rdi
    call .Lmenu_strlen
    test eax, eax
    jz .Lmr_next
    cmp eax, [rbp + MR_rem]
    jbe 1f
    mov eax, [rbp + MR_rem]
1:  mov [rbp + MR_nlen], eax
    mov ecx, [rbp + MR_muted]
    mov eax, [rbp + MR_i]
    cmp eax, [rip + .Lmenu_state + M_sel]
    jne 2f
    mov ecx, [rbp + MR_fg]
2:  mov rdi, rbx
    mov esi, [rbp + MR_col]
    mov edx, [rbp + MR_yy]
    xor r8d, r8d
    mov r9d, [rbp + MR_attrs]
    or r9d, .LA_DIM
    sub rsp, 16
    mov rax, [rbp + MR_nptr]
    mov [rsp], rax
    mov eax, [rbp + MR_nlen]
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16

.Lmr_next:
    inc dword ptr [rbp + MR_r]
    jmp .Lmr_row

.Lmr_zero:
    xor eax, eax
    EPILOGUE
