.include "opcode.inc"
.include "core/core.inc"
# prompt_compose_test: machine-checks the system prompt composed by
# prompt_build(): content presence, boundary invariants and the explicit
# SKIP-list absences described below. The date is implemented and asserted by
# the has-env-date / has-env-date-production / date-* checks below -- see
# ADR-12.
#
# Golden output: tests/data/prompt_compose_test.expected (one "ok <name>" line
# per check; the first failing check prints "FAIL <name>" and exits nonzero).
#
# Groups:
#   (A) content presence: identity, rules, environment, skills instruction and
#       one distinctive substring per rewritten tool description (G1-G6, G8).
#   (B) section-boundary invariants (transplant T2 / ADR-8): exactly one
#       trailing newline, XML wrappers balanced and properly nested, no block
#       emitted twice.
#   (C) SKIP-list absence: no "- name:" bullets (G13), no cache_control or
#       ephemeral (G16), no nested <name>/<description>/<location> skill tags
#       (G15). These are absences only; the date, by contrast, IS asserted --
#       by has-env-date, has-env-date-production and the date-* epoch vectors
#       (group G, ADR-12).
#   (D) per-provider serialization + placement: Anthropic system block (G20),
#       OpenAI chat messages[0] system (G21), Responses top-level instructions
#       with no role:system input item (G10), Responses tool_choice/
#       parallel_tool_calls (G11, Responses-only), Ollama/ollama-cloud
#       max_tokens vs everyone else's max_completion_tokens (G12).
#   (F) FIX 3 (ADR-11 / CR5-CR6#9): the system string delivered to each of the
#       three adapters is byte-identical to the others and to prompt_build's
#       output (asserts ADR-7 rather than three independent substring checks).
#
# The composed system prompt is produced by prompt_build() with the built-in
# tool registry (tools_init) and a fake config/project tree, and the platform
# is pinned through the g_prompt_platform seam so one fixture serves every
# target (linux-x86_64 and linux-aarch64).

.bss
.p2align 3
t_sys:  .zero SB_SIZE          # composed system prompt
# O4: production-path prompt (g_prompt_platform left at its default 0) and the
# dynamically built "- platform: <os_platform()>" needle.
t_sys_prod: .zero SB_SIZE
t_needle:   .zero 64
t_date:  .zero SB_SIZE          # group G: pc_date_from_secs scratch
t_nd_sb: .zero SB_SIZE          # "- date: <real date>" production needle
t_body: .zero SB_SIZE          # provider request body
t_tr:   .zero TR_SIZE
# FIX 3: one request body per provider adapter (built side by side so their
# system regions can be compared byte-for-byte) plus the JSON encoding of the
# composed prompt produced by the production encoder jsonw_str.
t_body_a: .zero SB_SIZE
t_body_c: .zero SB_SIZE
t_body_r: .zero SB_SIZE
t_enc:    .zero SB_SIZE

.section .rodata
# ---- fake tree paths / contents ----------------------------------------
.Ld_build:  .asciz "build"
.Ld_pp:     .asciz "build/pp_tree"
.Ld_cfg:    .asciz "build/pp_tree/config"
.Ld_skills: .asciz "build/pp_tree/config/skills"
.Ld_one:    .asciz "build/pp_tree/config/skills/one"
.Ld_proj:   .asciz "build/pp_tree/proj"

.Lc_cfg:    .asciz "build/pp_tree/config"
.Lc_proj:   .asciz "build/pp_tree/proj"
.Lc_plat:   .asciz "testplat"
.Lc_date:   .asciz "2000-02-29"
.Ln_plat_prefix: .asciz "- platform: "

.Lf_append: .asciz "build/pp_tree/config/APPEND_SYSTEM.md"
.Lc_append: .asciz "Addendum line.\n"
.Lf_one:    .asciz "build/pp_tree/config/skills/one/SKILL.md"
.Lc_one:    .asciz "---\nname: one\ndescription: First skill\n---\nBody one.\n"
.Lf_agents: .asciz "build/pp_tree/proj/AGENTS.md"
.Lc_agents: .asciz "Project instruction A.\n"

# ---- transcript ---------------------------------------------------------
.Lhi:       .asciz "hi"

# ---- provider model descriptors ----------------------------------------
.Lmd_id_a:   .asciz "claude-test"
.Lmd_id_o:   .asciz "gpt-test"
.Lmd_name:   .asciz "Test Model"
.Lmd_api_a:  .asciz "anthropic-messages"
.Lmd_api_o:  .asciz "openai-chat"
.Lmd_api_r:  .asciz "openai-responses"
.Lmd_prov_test:   .asciz "test"
.Lmd_prov_ollama: .asciz "ollama"
.Lmd_prov_cloud:  .asciz "ollama-cloud"
.Lmd_base:   .asciz "https://example.invalid"

# ---- content needles (group A) -----------------------------------------
.Ln_identity:     .asciz "working directly in the user's environment"
.Ln_never_invent: .asciz "never invent tool output"
.Ln_read_before:  .asciz "Read a file before editing it"
.Ln_report:       .asciz "report failures instead of guessing"
.Ln_keep_short:   .asciz "Keep answers short and direct"
.Ln_env_header:   .asciz "# Environment"
.Ln_env_cwd:      .asciz "- cwd: "
.Ln_env_plat:     .asciz "- platform: testplat"
.Ln_env_date:     .asciz "- date: 2000-02-29"
.Ln_skills_instr: .asciz "Read a skill's file when its description matches the task"
.Ln_desc_read:    .asciz "Read a text file with numbered lines"
.Ln_desc_bash:    .asciz "Run a shell command with sh -lc"
.Ln_desc_edit:    .asciz "Each oldText must match exactly once"
.Ln_desc_write:   .asciz "creating parent directories"
.Ln_desc_ls:      .asciz "directories with a trailing /"
.Ln_desc_find:    .asciz "whose path matches a glob pattern"
.Ln_desc_grep:    .asciz "returns path:line:text"
# FIX 1 (ADR-11 / CR3): the three verified opcode facts added to the tool
# descriptions (grep 500-byte output cap, find 20000-entry walk cap, ls
# hidden-file inclusion).
.Ln_desc_ls_hidden: .asciz "hidden files are included"
.Ln_desc_find_cap:  .asciz "20000 entries"
.Ln_desc_grep_cap:  .asciz "500 bytes"

# ---- XML boundary needles (group B) ------------------------------------
.Ln_add_open:    .asciz "<addendum>"
.Ln_add_close:   .asciz "</addendum>"
.Ln_proj_open:   .asciz "<project_instructions"
.Ln_proj_close:  .asciz "</project_instructions>"
.Ln_sk_open:     .asciz "<available_skills>"
.Ln_sk_close:    .asciz "</available_skills>"
.Ln_skill_open:  .asciz "<skill "
.Ln_skill_close: .asciz "</skill>"

# ---- SKIP-list absence needles (group C) -------------------------------
.Ln_dash_read:   .asciz "- read:"          # G13
.Ln_cache_ctrl:  .asciz "cache_control"    # G16
.Ln_ephemeral:   .asciz "ephemeral"        # G16
.Ln_name_tag:    .asciz "<name>"           # G15
.Ln_desc_tag:    .asciz "<description>"    # G15
.Ln_loc_tag:     .asciz "<location>"       # G15

# ---- provider body needles (group D) -----------------------------------
.Ln_anth_sys:      .asciz "\"system\":[{\"type\":\"text\""
.Ln_chat_sys:      .asciz "\"messages\":[{\"role\":\"system\""
.Ln_instr:         .asciz "\"instructions\""
.Ln_sys_role:      .asciz "\"role\":\"system\""
.Ln_tool_choice:   .asciz "\"tool_choice\":\"auto\""
.Ln_parallel:      .asciz "\"parallel_tool_calls\":true"
.Ln_parallel_key:  .asciz "parallel_tool_calls"
.Ln_max_tokens:    .asciz "\"max_tokens\""
.Ln_max_completion: .asciz "\"max_completion_tokens\""

# ---- cross-provider system-string markers (group F, FIX 3) -------------
# The exact JSON prefix emitted immediately before the system value in each
# provider body: anthropic system[0].text, openai-chat messages[0].content,
# responses top-level instructions. The value runs to the next unescaped quote
# (sys_region skips '\'-escaped bytes, e.g. the '"' in <skill name="...">).
.Lmk_anth:  .asciz "\"system\":[{\"type\":\"text\",\"text\":\""
.Lmk_chat:  .asciz "\"messages\":[{\"role\":\"system\",\"content\":\""
.Lmk_instr: .asciz "\"instructions\":\""

# ---- date conversion epoch vectors (group G, ADR-12) -------------------
# Known epoch seconds -> UTC civil date, independently cross-checked against
# Python datetime.  A plausible-looking wrong date is a hallucination-class
# defect, so the conversion is asserted, never eyeballed.
.Ln_date_prefix:    .asciz "- date: "
.Lv_date_epoch:     .asciz "1970-01-01"   # 0
.Lv_date_leap:      .asciz "2000-02-29"   # 951782400, leap day
.Lv_date_century:   .asciz "2100-01-01"   # 4102444800, non-leap century
.Lv_date_2038:      .asciz "2038-01-19"   # 2147483647, 32-bit boundary
.Lv_date_recent:    .asciz "2023-11-14"   # 1700000000
.Lv_date_mid:       .asciz "2009-02-13"   # 1234567890, month rollover
.Lk_date_epoch:     .asciz "date-epoch"
.Lk_date_leap:      .asciz "date-leap-day"
.Lk_date_century:   .asciz "date-century-nonleap"
.Lk_date_2038:      .asciz "date-2038-boundary"
.Lk_date_recent:    .asciz "date-recent"
.Lk_date_mid:       .asciz "date-month-rollover"

# ---- duplicate-section needles -----------------------------------------
.Ln_rules_header: .asciz "# Rules"
.Ln_tools_header: .asciz "# Tools"

# ---- check names (group A) ---------------------------------------------
.Lk_identity:     .asciz "has-identity"
.Lk_never_invent: .asciz "has-rules-never-invent"
.Lk_read_before:  .asciz "has-rules-read-before-edit"
.Lk_report:       .asciz "has-rules-report-failures"
.Lk_keep_short:   .asciz "has-rules-keep-short"
.Lk_env_header:   .asciz "has-env-header"
.Lk_env_cwd:      .asciz "has-env-cwd"
.Lk_env_plat:     .asciz "has-env-platform"
.Lk_env_plat_prod: .asciz "has-env-platform-production"
.Lk_env_date:     .asciz "has-env-date"
.Lk_env_date_prod: .asciz "has-env-date-production"
.Lk_skills_instr: .asciz "has-skills-instruction"
.Lk_desc_read:    .asciz "has-desc-read"
.Lk_desc_bash:    .asciz "has-desc-bash"
.Lk_desc_edit:    .asciz "has-desc-edit"
.Lk_desc_write:   .asciz "has-desc-write"
.Lk_desc_ls:      .asciz "has-desc-ls"
.Lk_desc_find:    .asciz "has-desc-find"
.Lk_desc_grep:    .asciz "has-desc-grep"
.Lk_desc_ls_hidden: .asciz "has-desc-ls-hidden"
.Lk_desc_find_cap:  .asciz "has-desc-find-cap"
.Lk_desc_grep_cap:  .asciz "has-desc-grep-cap"

# ---- check names (group B) ---------------------------------------------
.Lk_end_newline:  .asciz "end-single-newline"
.Lk_add_count:    .asciz "xml-addendum-open"
.Lk_add_count2:   .asciz "xml-addendum-close"
.Lk_proj_count:   .asciz "xml-project-open"
.Lk_proj_count2:  .asciz "xml-project-close"
.Lk_sk_count:     .asciz "xml-skills-open"
.Lk_sk_count2:    .asciz "xml-skills-close"
.Lk_skill_count:  .asciz "xml-skill-open"
.Lk_skill_count2: .asciz "xml-skill-close"
.Lk_nest_add:     .asciz "nest-addendum"
.Lk_nest_proj:    .asciz "nest-project"
.Lk_nest_sk:      .asciz "nest-skills"
.Lk_nest_skill:   .asciz "nest-skill"
.Lk_bound_add_proj:   .asciz "boundary-addendum-project"
.Lk_bound_proj_sk:    .asciz "boundary-project-skills"
.Lk_bound_sk_skill:   .asciz "boundary-skills-skill"
.Lk_bound_skill_sk:   .asciz "boundary-skill-skills"
.Lk_once_env:     .asciz "once-environment"
.Lk_once_rules:   .asciz "once-rules"
.Lk_once_tools:   .asciz "once-tools"

# ---- check names (group C) ---------------------------------------------
.Lk_abs_dash_read: .asciz "absent-dash-read"
.Lk_abs_cache:     .asciz "absent-cache-control"
.Lk_abs_ephemeral: .asciz "absent-ephemeral"
.Lk_abs_name_tag:  .asciz "absent-name-tag"
.Lk_abs_desc_tag:  .asciz "absent-description-tag"
.Lk_abs_loc_tag:   .asciz "absent-location-tag"

# ---- check names (group D) ---------------------------------------------
.Lk_anth_sys:        .asciz "anthropic-system-block"
.Lk_anth_no_parallel: .asciz "anthropic-no-parallel"
.Lk_chat_sys:        .asciz "openai-chat-system-first"
.Lk_chat_no_parallel: .asciz "openai-chat-no-parallel"
.Lk_resp_instr:      .asciz "responses-instructions"
.Lk_resp_prompt:     .asciz "responses-has-prompt"
.Lk_resp_no_sys:     .asciz "responses-no-system-role"
.Lk_resp_choice:     .asciz "responses-tool-choice"
.Lk_resp_parallel:   .asciz "responses-parallel-tool-calls"
.Lk_ollama_max:      .asciz "ollama-max-tokens"
.Lk_ollama_no_max:   .asciz "ollama-no-max-completion"
.Lk_cloud_max:       .asciz "ollama-cloud-max-tokens"
.Lk_cloud_no_max:    .asciz "ollama-cloud-no-max-completion"
.Lk_test_max:        .asciz "non-ollama-max-completion"
.Lk_test_no_max:     .asciz "non-ollama-no-max-tokens"

# ---- check names (group F: FIX 3 cross-provider system-string identity) --
.Lk_sys_eq_ac:      .asciz "sys-eq-anth-chat"
.Lk_sys_eq_cr:      .asciz "sys-eq-chat-resp"
.Lk_sys_eq_prompt:  .asciz "sys-eq-anth-prompt"

# ---- ok/FAIL printing ---------------------------------------------------
.Lok_pfx:    .asciz "ok "
.Lfail_pfx:  .asciz "FAIL "
.Lnl:        .asciz "\n"
.Lm_done:    .asciz "prompt composition done\n"

.section .data
.p2align 3
md_anth:
    .quad .Lmd_id_a
    .quad .Lmd_name
    .quad .Lmd_api_a
    .quad .Lmd_prov_test
    .quad .Lmd_base
    .long 200000
    .long 8192
    .long MDF_REASONING
    .long 0
md_chat:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov_test
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long 0
    .long 0
md_resp:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_r
    .quad .Lmd_prov_test
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long 0
    .long 0
md_ollama:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov_ollama
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long MDF_NO_KEY
    .long 0
md_cloud:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov_cloud
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long 0
    .long 0

.text

# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# t_mkdir(path): create the directory, an existing one is fine
t_mkdir:
    mov esi, 0755
    jmp os_mkdir

# t_write(path cstr, content cstr)
t_write:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rsi
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Ltw_done
    mov r12d, eax
    mov rdi, rbx
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, r12d
    call write_all
    mov edi, r12d
    call os_close
.Ltw_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# ok_line(name cstr): print "ok <name>\n"
ok_line:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + .Lok_pfx]
    call print
    mov rdi, rbx
    call print
    lea rdi, [rip + .Lnl]
    call print
    pop rbx
    ret

# fail_line(name cstr): print "FAIL <name>\n"
fail_line:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + .Lfail_pfx]
    call print
    mov rdi, rbx
    call print
    lea rdi, [rip + .Lnl]
    call print
    pop rbx
    ret

# sb_has(sb, needle cstr) -> 1 | 0
sb_has:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    call strlen
    mov rcx, rax
    mov rdi, [r12 + SB_ptr]
    test rdi, rdi
    jz .Lsh_no
    mov rsi, [r12 + SB_len]
    mov rdx, r13
    call str_find
    cmp rax, -1
    setne al
    movzx eax, al
    EPILOGUE
.Lsh_no:
    xor eax, eax
    EPILOGUE

# sb_index(sb, needle cstr) -> index | -1
sb_index:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    call strlen
    mov rcx, rax
    mov rdi, [r12 + SB_ptr]
    test rdi, rdi
    jz .Lsi_no
    mov rsi, [r12 + SB_len]
    mov rdx, r13
    call str_find
    EPILOGUE
.Lsi_no:
    mov rax, -1
    EPILOGUE

# sb_count(sb, needle cstr) -> non-overlapping occurrence count
sb_count:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    call strlen
    mov r14, rax                       # nlen
    xor r15d, r15d                     # count
    xor ebx, ebx                       # offset
    test r14, r14
    jz .Lsc_done
.Lsc_loop:
    mov rax, [r12 + SB_len]
    cmp rbx, rax
    jae .Lsc_done
    mov rdi, [r12 + SB_ptr]
    test rdi, rdi
    jz .Lsc_done
    add rdi, rbx
    mov rsi, [r12 + SB_len]
    sub rsi, rbx
    mov rdx, r13
    mov rcx, r14
    call str_find
    cmp rax, -1
    je .Lsc_done
    add rbx, rax
    add rbx, r14
    inc r15
    jmp .Lsc_loop
.Lsc_done:
    mov rax, r15
    EPILOGUE

# expect_has(sb, needle, name): ok if present else FAIL + exit 1
expect_has:
    PROLOGUE 0
    mov r12, rdx                       # name
    call sb_has
    test eax, eax
    jz .Leh_fail
    mov rdi, r12
    call ok_line
    EPILOGUE
.Leh_fail:
    mov rdi, r12
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# expect_absent(sb, needle, name): ok if absent else FAIL + exit 1
expect_absent:
    PROLOGUE 0
    mov r12, rdx                       # name
    call sb_has
    test eax, eax
    jnz .Lea_fail
    mov rdi, r12
    call ok_line
    EPILOGUE
.Lea_fail:
    mov rdi, r12
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# expect_count(sb, needle, want, name): ok if count == want else FAIL + exit 1
expect_count:
    PROLOGUE 0
    mov r12, rdx                       # want
    mov r13, rcx                       # name
    call sb_count
    cmp rax, r12
    jne .Lec_fail
    mov rdi, r13
    call ok_line
    EPILOGUE
.Lec_fail:
    mov rdi, r13
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# expect_lt(sb, a, b, name): ok if a and b each occur once and index(a)<index(b)
expect_lt:
    PROLOGUE 0
    mov rbx, rdi                       # sb
    mov r12, rsi                       # a
    mov r13, rdx                       # b
    mov r14, rcx                       # name
    mov rdi, rbx
    mov rsi, r12
    call sb_index
    cmp rax, -1
    je .Lelt_fail
    mov r15, rax
    mov rdi, rbx
    mov rsi, r13
    call sb_index
    cmp rax, -1
    je .Lelt_fail
    cmp r15, rax
    jae .Lelt_fail
    mov rdi, r14
    call ok_line
    EPILOGUE
.Lelt_fail:
    mov rdi, r14
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# expect_end_newline(sb, name): exactly one trailing '\n'
expect_end_newline:
    PROLOGUE 0
    mov r12, rsi                       # name
    mov rax, [rdi + SB_len]
    cmp rax, 2
    jb .Leen_fail
    mov rcx, [rdi + SB_ptr]
    test rcx, rcx
    jz .Leen_fail
    cmp byte ptr [rcx + rax - 1], 10
    jne .Leen_fail
    cmp byte ptr [rcx + rax - 2], 10
    je .Leen_fail
    mov rdi, r12
    call ok_line
    EPILOGUE
.Leen_fail:
    mov rdi, r12
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# prov_body(vtable, md, out sb, sys cstr): PV_new + PV_build(ctx, out, sys,
# &t_tr) + PV_free. Follows the in-process path used by prov_test/responses_test
# (the body is the PV_build output buffer, not the HTTP-framed mock_sent()
# capture; the capture only adds the request line/headers and is not needed to
# check JSON placement).
#   rdi=vtable, rsi=md, rdx=out sb, rcx=sys cstr
prov_body:
    PROLOGUE 0
    mov rbx, rdi                       # vtable
    mov r12, rdx                       # out sb
    mov r13, rcx                       # sys
    mov rdi, rsi                       # md
    call [rbx + PV_new]
    mov r14, rax                       # ctx
    mov rdi, r12
    call sb_clear
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rip + t_tr]
    call [rbx + PV_build]
    mov r15d, eax
    mov rdi, r14
    call [rbx + PV_free]
    mov eax, r15d
    EPILOGUE

# t_needle_plat(buf): buf = "- platform: " + os_platform(). Used by the O4
# production-path check; works on every target (linux -> "linux", macos ->
# "macos") because it compares against os_platform()'s actual return value.
t_needle_plat:
    push rbx
    push r12
    mov rbx, rdi
    lea rsi, [rip + .Ln_plat_prefix]
    xor ecx, ecx
1:  mov al, [rsi + rcx]
    mov [rbx + rcx], al
    inc rcx
    test al, al
    jnz 1b
    dec rcx                        # overwrite the terminating NUL
    call os_platform
    xor edx, edx
2:  mov r8b, [rax + rdx]
    mov [rbx + rcx], r8b
    inc rcx
    inc rdx
    test r8b, r8b
    jnz 2b
    pop r12
    pop rbx
    ret

# ---- FIX 3 (ADR-11): cross-provider system-string identity ----------------
# The three adapters must deliver identical system text (ADR-7). Rather than
# three independent substring checks (which would pass even if the values
# differed), extract each body's system-value region and compare the regions
# byte-for-byte, then compare the region to the production JSON encoding of
# prompt_build's output.

# sys_region(sb, marker cstr, out_len_ptr) -> start ptr | 0
# The region is the JSON string content immediately after `marker`, up to the
# next UNESCAPED '"' (a '\'-escaped byte is skipped, so the '"' in the
# <skill name="..."> wrapper is not a terminator). 0 is returned for a missing
# marker, a missing closing quote or an empty region, so the caller FAILs
# instead of passing vacuously.
FN sys_region
    PROLOGUE 16
    mov rbx, rdi                       # body sb
    mov r12, rsi                       # marker cstr
    mov [rsp], rdx                     # out_len_ptr
    mov rdi, r12
    call strlen
    mov r13, rax                       # marker length
    mov rdi, rbx
    mov rsi, r12
    call sb_index
    cmp rax, -1
    je .Lsr_zero
    add rax, r13                       # region start offset
    mov r14, rax
    mov r15, [rbx + SB_len]
    cmp r14, r15
    jae .Lsr_zero
    mov rcx, r14
.Lsr_scan:
    cmp rcx, r15
    jae .Lsr_zero                      # no closing quote
    mov rdx, [rbx + SB_ptr]
    movzx eax, byte ptr [rdx + rcx]
    cmp al, 0x5c                       # '\\': skip the escaped byte
    jne 1f
    add rcx, 2
    jmp .Lsr_scan
1:  cmp al, '"'
    je .Lsr_found
    inc rcx
    jmp .Lsr_scan
.Lsr_found:
    sub rcx, r14                       # region length
    test rcx, rcx
    jz .Lsr_zero                       # empty value -> treat as not found
    mov rax, [rbx + SB_ptr]
    add rax, r14                       # start ptr
    mov rdx, [rsp]
    mov [rdx], rcx                     # *out_len
    EPILOGUE
.Lsr_zero:
    xor eax, eax
    EPILOGUE

# expect_sys_eq(sbA, markerA, sbB, markerB, name): ok if both system regions
# exist and are byte-identical (length and content) else FAIL + exit 1.
FN expect_sys_eq
    PROLOGUE 32
    mov rbx, rdx                       # sbB
    mov r12, rcx                       # markerB
    mov r13, r8                        # name
    mov r14, rsi                       # markerA
    lea rdx, [rsp]
    mov rsi, r14
    call sys_region                    # rdi = sbA
    test rax, rax
    jz .Lseq_fail
    mov r15, rax                       # ptrA
    mov r14, [rsp]                     # lenA
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp + 8]
    call sys_region
    test rax, rax
    jz .Lseq_fail
    mov rbx, rax                       # ptrB
    mov r12, [rsp + 8]                 # lenB
    cmp r14, r12
    jne .Lseq_fail
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r14
    call memeq
    test eax, eax
    jz .Lseq_fail
    mov rdi, r13
    call ok_line
    EPILOGUE
.Lseq_fail:
    mov rdi, r13
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# expect_sys_eq_enc(body sb, marker, enc sb, name): ok if the body's system
# region equals the content of `enc` (a jsonw_str buffer, so `"<escaped>"`)
# else FAIL + exit 1. Ties the delivered value to prompt_build's output.
FN expect_sys_eq_enc
    PROLOGUE 16
    mov rbx, rdx                       # enc sb ("...")
    mov r12, rcx                       # name
    mov r13, rsi                       # marker
    lea rdx, [rsp]
    mov rsi, r13
    call sys_region                    # rdi = body sb
    test rax, rax
    jz .Lsee_fail
    mov r14, rax                       # region ptr
    mov r15, [rsp]                     # region len
    mov rcx, [rbx + SB_len]
    cmp rcx, 2                         # must be "..." with content
    jb .Lsee_fail
    sub rcx, 2
    cmp rcx, r15
    jne .Lsee_fail
    mov rdi, r14
    mov rsi, [rbx + SB_ptr]
    inc rsi                            # skip the opening quote
    mov rdx, r15
    call memeq
    test eax, eax
    jz .Lsee_fail
    mov rdi, r12
    call ok_line
    EPILOGUE
.Lsee_fail:
    mov rdi, r12
    call fail_line
    mov edi, 1
    call os_exit
    ud2

# date_vec(secs i64, want cstr, name): ok if pc_date_from_secs(secs, t_date)
# equals `want` (byte-exact) else FAIL + exit 1. This asserts the conversion
# algorithm itself, independent of the prompt.
date_vec:
    PROLOGUE 0
    mov rbx, rdi                       # secs
    mov r12, rsi                       # want
    mov r13, rdx                       # name
    lea rdi, [rip + t_date]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + t_date]
    call pc_date_from_secs
    mov rdi, r12
    call strlen
    mov r14, rax                       # want length
    mov rax, [rip + t_date + SB_len]
    cmp rax, r14
    jne .Ldv_fail
    mov rdi, [rip + t_date + SB_ptr]
    test rdi, rdi
    jz .Ldv_fail
    mov rsi, r12
    mov rdx, r14
    call memeq
    test eax, eax
    jz .Ldv_fail
    mov rdi, r13
    call ok_line
    EPILOGUE
.Ldv_fail:
    mov rdi, r13
    call fail_line
    mov edi, 1
    call os_exit
    ud2

FN opcode_main
    PROLOGUE

    # ---- fake tree -------------------------------------------------------
    lea rdi, [rip + .Ld_build]
    call t_mkdir
    lea rdi, [rip + .Ld_pp]
    call t_mkdir
    lea rdi, [rip + .Ld_cfg]
    call t_mkdir
    lea rdi, [rip + .Ld_skills]
    call t_mkdir
    lea rdi, [rip + .Ld_one]
    call t_mkdir
    lea rdi, [rip + .Ld_proj]
    call t_mkdir

    lea rdi, [rip + .Lf_append]
    lea rsi, [rip + .Lc_append]
    call t_write
    lea rdi, [rip + .Lf_one]
    lea rsi, [rip + .Lc_one]
    call t_write
    lea rdi, [rip + .Lf_agents]
    lea rsi, [rip + .Lc_agents]
    call t_write

    # config + trusted project + fixed platform and date
    lea rax, [rip + .Lc_cfg]
    mov [rip + g_config_home], rax
    mov qword ptr [rip + g_config_approve], 1
    lea rax, [rip + .Lc_plat]
    mov [rip + g_prompt_platform], rax
    lea rax, [rip + .Lc_date]
    mov [rip + g_prompt_date], rax

    # all seven built-in tools (their descriptions are checked in group A)
    call tools_init

    # ---- compose the system prompt --------------------------------------
    call tools_active
    mov rsi, rax
    lea rdi, [rip + t_sys]
    lea rdx, [rip + .Lc_proj]
    call prompt_build
    test eax, eax
    jnz .Lmain_fail

    # ================= (A) content presence ==============================
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_identity]
    lea rdx, [rip + .Lk_identity]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_never_invent]
    lea rdx, [rip + .Lk_never_invent]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_read_before]
    lea rdx, [rip + .Lk_read_before]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_report]
    lea rdx, [rip + .Lk_report]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_keep_short]
    lea rdx, [rip + .Lk_keep_short]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_env_header]
    lea rdx, [rip + .Lk_env_header]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_env_cwd]
    lea rdx, [rip + .Lk_env_cwd]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_env_plat]
    lea rdx, [rip + .Lk_env_plat]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_env_date]
    lea rdx, [rip + .Lk_env_date]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_skills_instr]
    lea rdx, [rip + .Lk_skills_instr]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_read]
    lea rdx, [rip + .Lk_desc_read]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_bash]
    lea rdx, [rip + .Lk_desc_bash]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_edit]
    lea rdx, [rip + .Lk_desc_edit]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_write]
    lea rdx, [rip + .Lk_desc_write]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_ls]
    lea rdx, [rip + .Lk_desc_ls]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_ls_hidden]
    lea rdx, [rip + .Lk_desc_ls_hidden]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_find]
    lea rdx, [rip + .Lk_desc_find]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_find_cap]
    lea rdx, [rip + .Lk_desc_find_cap]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_grep]
    lea rdx, [rip + .Lk_desc_grep]
    call expect_has
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_grep_cap]
    lea rdx, [rip + .Lk_desc_grep_cap]
    call expect_has

    # ================= (B) section-boundary invariants ===================
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Lk_end_newline]
    call expect_end_newline

    # wrappers balanced: each opens and closes exactly once
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_add_open]
    mov edx, 1
    lea rcx, [rip + .Lk_add_count]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_add_close]
    mov edx, 1
    lea rcx, [rip + .Lk_add_count2]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_proj_open]
    mov edx, 1
    lea rcx, [rip + .Lk_proj_count]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_proj_close]
    mov edx, 1
    lea rcx, [rip + .Lk_proj_count2]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_sk_open]
    mov edx, 1
    lea rcx, [rip + .Lk_sk_count]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_sk_close]
    mov edx, 1
    lea rcx, [rip + .Lk_sk_count2]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_skill_open]
    mov edx, 1
    lea rcx, [rip + .Lk_skill_count]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_skill_close]
    mov edx, 1
    lea rcx, [rip + .Lk_skill_count2]
    call expect_count

    # properly nested / non-interleaved (open before close, in emission order)
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_add_open]
    lea rdx, [rip + .Ln_add_close]
    lea rcx, [rip + .Lk_nest_add]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_proj_open]
    lea rdx, [rip + .Ln_proj_close]
    lea rcx, [rip + .Lk_nest_proj]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_sk_open]
    lea rdx, [rip + .Ln_sk_close]
    lea rcx, [rip + .Lk_nest_sk]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_skill_open]
    lea rdx, [rip + .Ln_skill_close]
    lea rcx, [rip + .Lk_nest_skill]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_add_close]
    lea rdx, [rip + .Ln_proj_open]
    lea rcx, [rip + .Lk_bound_add_proj]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_proj_close]
    lea rdx, [rip + .Ln_sk_open]
    lea rcx, [rip + .Lk_bound_proj_sk]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_sk_open]
    lea rdx, [rip + .Ln_skill_open]
    lea rcx, [rip + .Lk_bound_sk_skill]
    call expect_lt
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_skill_close]
    lea rdx, [rip + .Ln_sk_close]
    lea rcx, [rip + .Lk_bound_skill_sk]
    call expect_lt

    # no block emitted twice
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_env_header]
    mov edx, 1
    lea rcx, [rip + .Lk_once_env]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_rules_header]
    mov edx, 1
    lea rcx, [rip + .Lk_once_rules]
    call expect_count
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_tools_header]
    mov edx, 1
    lea rcx, [rip + .Lk_once_tools]
    call expect_count

    # ================= (C) SKIP-list absence =============================
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_dash_read]
    lea rdx, [rip + .Lk_abs_dash_read]
    call expect_absent
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_cache_ctrl]
    lea rdx, [rip + .Lk_abs_cache]
    call expect_absent
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_ephemeral]
    lea rdx, [rip + .Lk_abs_ephemeral]
    call expect_absent
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_name_tag]
    lea rdx, [rip + .Lk_abs_name_tag]
    call expect_absent
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_desc_tag]
    lea rdx, [rip + .Lk_abs_desc_tag]
    call expect_absent
    lea rdi, [rip + t_sys]
    lea rsi, [rip + .Ln_loc_tag]
    lea rdx, [rip + .Lk_abs_loc_tag]
    call expect_absent

    # ================= (D) per-provider serialization ====================
    # minimal transcript: one user message
    lea rdi, [rip + t_tr]
    call tr_init
    mov edi, MR_USER
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhi]
    mov ecx, 2
    call msg_add_block
    lea rdi, [rip + t_tr]
    mov rsi, rbx
    call tr_push

    # Anthropic: system stays a {"type":"text"} block (G20); no parallel flag
    lea rdi, [rip + prov_anthropic]
    lea rsi, [rip + md_anth]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_anth_sys]
    lea rdx, [rip + .Lk_anth_sys]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_parallel_key]
    lea rdx, [rip + .Lk_anth_no_parallel]
    call expect_absent

    # OpenAI chat: messages[0] is the system role (G21); no parallel flag
    lea rdi, [rip + prov_openai]
    lea rsi, [rip + md_chat]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_chat_sys]
    lea rdx, [rip + .Lk_chat_sys]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_parallel_key]
    lea rdx, [rip + .Lk_chat_no_parallel]
    call expect_absent

    # OpenAI Responses: top-level instructions, NO role:system input item (G10)
    lea rdi, [rip + prov_openai_responses]
    lea rsi, [rip + md_resp]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_instr]
    lea rdx, [rip + .Lk_resp_instr]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_identity]
    lea rdx, [rip + .Lk_resp_prompt]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_sys_role]
    lea rdx, [rip + .Lk_resp_no_sys]
    call expect_absent
    # Responses-only tool-choice flags (G11)
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_tool_choice]
    lea rdx, [rip + .Lk_resp_choice]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_parallel]
    lea rdx, [rip + .Lk_resp_parallel]
    call expect_has

    # G12: Ollama / ollama-cloud use max_tokens; everyone else max_completion_tokens
    lea rdi, [rip + prov_openai]
    lea rsi, [rip + md_ollama]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_tokens]
    lea rdx, [rip + .Lk_ollama_max]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_completion]
    lea rdx, [rip + .Lk_ollama_no_max]
    call expect_absent

    lea rdi, [rip + prov_openai]
    lea rsi, [rip + md_cloud]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_tokens]
    lea rdx, [rip + .Lk_cloud_max]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_completion]
    lea rdx, [rip + .Lk_cloud_no_max]
    call expect_absent

    lea rdi, [rip + prov_openai]
    lea rsi, [rip + md_chat]
    lea rdx, [rip + t_body]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_completion]
    lea rdx, [rip + .Lk_test_max]
    call expect_has
    lea rdi, [rip + t_body]
    lea rsi, [rip + .Ln_max_tokens]
    lea rdx, [rip + .Lk_test_no_max]
    call expect_absent

    # ================= (E) production os_platform()/date path (O4) =======
    # Compose with the g_prompt_platform and g_prompt_date seams at their
    # production default (0) and assert the emitted "- platform: " value equals
    # os_platform()'s actual return value and the emitted "- date: " equals the
    # real UTC date. Target-independent: no per-target fixture needed.
    mov qword ptr [rip + g_prompt_platform], 0
    mov qword ptr [rip + g_prompt_date], 0
    call tools_active
    mov rsi, rax
    lea rdi, [rip + t_sys_prod]
    lea rdx, [rip + .Lc_proj]
    call prompt_build
    test eax, eax
    jnz .Lmain_fail
    lea rdi, [rip + t_needle]
    call t_needle_plat
    lea rdi, [rip + t_sys_prod]
    lea rsi, [rip + t_needle]
    lea rdx, [rip + .Lk_env_plat_prod]
    call expect_has
    # date production path: build "- date: <pc_date_from_secs(os_now_ns(0))>"
    # and assert the prompt carries it. The conversion's own correctness is
    # covered by the group-G epoch vectors; this checks the clock wiring.
    lea rdi, [rip + t_nd_sb]
    call sb_clear
    lea rdi, [rip + t_nd_sb]
    lea rsi, [rip + .Ln_date_prefix]
    call sb_push_cstr
    xor edi, edi
    call os_now_ns
    test rax, rax
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov rcx, 1000000000
    div rcx
    mov rdi, rax
    lea rsi, [rip + t_nd_sb]
    call pc_date_from_secs
    lea rdi, [rip + t_sys_prod]
    mov rsi, [rip + t_nd_sb + SB_ptr]
    lea rdx, [rip + .Lk_env_date_prod]
    call expect_has

    # ================= (F) cross-provider system identity (FIX 3) ========
    # FIX 3 / ADR-11: build one body per adapter from the SAME composed prompt
    # and assert the three delivered system strings are byte-identical to each
    # other and to prompt_build's output through the production encoder. This
    # is a genuine equality (region bytes + length), not three substring probes.
    lea rdi, [rip + prov_anthropic]
    lea rsi, [rip + md_anth]
    lea rdx, [rip + t_body_a]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + prov_openai]
    lea rsi, [rip + md_chat]
    lea rdx, [rip + t_body_c]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body
    lea rdi, [rip + prov_openai_responses]
    lea rsi, [rip + md_resp]
    lea rdx, [rip + t_body_r]
    mov rcx, [rip + t_sys + SB_ptr]
    call prov_body

    # expected escaped value: jsonw_str writes "<escaped prompt>"
    lea rdi, [rip + t_enc]
    call sb_clear
    lea rdi, [rip + t_enc]
    mov rsi, [rip + t_sys + SB_ptr]
    mov rdx, [rip + t_sys + SB_len]
    call jsonw_str

    # anthropic system[0].text == openai-chat messages[0].content
    lea rdi, [rip + t_body_a]
    lea rsi, [rip + .Lmk_anth]
    lea rdx, [rip + t_body_c]
    lea rcx, [rip + .Lmk_chat]
    lea r8,  [rip + .Lk_sys_eq_ac]
    call expect_sys_eq

    # openai-chat messages[0].content == responses instructions
    lea rdi, [rip + t_body_c]
    lea rsi, [rip + .Lmk_chat]
    lea rdx, [rip + t_body_r]
    lea rcx, [rip + .Lmk_instr]
    lea r8,  [rip + .Lk_sys_eq_cr]
    call expect_sys_eq

    # anthropic system[0].text == jsonw_str(prompt_build output)
    lea rdi, [rip + t_body_a]
    lea rsi, [rip + .Lmk_anth]
    lea rdx, [rip + t_enc]
    lea rcx, [rip + .Lk_sys_eq_prompt]
    call expect_sys_eq_enc

    # ================= (G) UTC date conversion (ADR-12) =================
    mov edi, 0
    lea rsi, [rip + .Lv_date_epoch]
    lea rdx, [rip + .Lk_date_epoch]
    call date_vec
    mov edi, 951782400
    lea rsi, [rip + .Lv_date_leap]
    lea rdx, [rip + .Lk_date_leap]
    call date_vec
    mov edi, 4102444800
    lea rsi, [rip + .Lv_date_century]
    lea rdx, [rip + .Lk_date_century]
    call date_vec
    mov edi, 2147483647
    lea rsi, [rip + .Lv_date_2038]
    lea rdx, [rip + .Lk_date_2038]
    call date_vec
    mov edi, 1700000000
    lea rsi, [rip + .Lv_date_recent]
    lea rdx, [rip + .Lk_date_recent]
    call date_vec
    mov edi, 1234567890
    lea rsi, [rip + .Lv_date_mid]
    lea rdx, [rip + .Lk_date_mid]
    call date_vec

    lea rdi, [rip + .Lm_done]
    call print

    lea rdi, [rip + t_sys]
    call sb_free
    lea rdi, [rip + t_sys_prod]
    call sb_free
    lea rdi, [rip + t_body]
    call sb_free
    lea rdi, [rip + t_body_a]
    call sb_free
    lea rdi, [rip + t_body_c]
    call sb_free
    lea rdi, [rip + t_body_r]
    call sb_free
    lea rdi, [rip + t_enc]
    call sb_free
    lea rdi, [rip + t_date]
    call sb_free
    lea rdi, [rip + t_nd_sb]
    call sb_free
    lea rdi, [rip + t_tr]
    call tr_free
    xor eax, eax
    EPILOGUE

.Lmain_fail:
    lea rdi, [rip + .Lmain_fail_msg]
    call print
    mov eax, 1
    EPILOGUE

.section .rodata
.Lmain_fail_msg: .asciz "FAIL prompt_build\n"
