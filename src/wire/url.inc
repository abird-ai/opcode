# wire/url.inc: the frozen Url layout, shared by every module that inspects a
# parsed URL. The offsets are also documented in src/wire/API.md; this file is
# the single source of truth for the assembler. Included after opcode.inc (it
# uses the STRUCT/F/ENDSTRUCT macros) by:
#   src/wire/url.s          (defines url_parse/url_copy_host/url_authority)
#   src/wire/http_client.s  (embeds the Url at HC_url)
#   src/app/fetch.s
#   src/app/update.s
#   src/core/agent.s, src/core/oauth.s, src/core/discover.s (to be switched)
#
# url_parse never copies or modifies the input: every pointer references either
# the input string or the static "/" path. Missing path -> "/" len 1.

STRUCT
F U_scheme, 8
F U_host, 8
F U_path, 8
F U_query, 8
F U_scheme_len, 4
F U_host_len, 4
F U_path_len, 4
F U_query_len, 4
F U_port, 2
F U_flags, 2
ENDSTRUCT U_SIZE

.equ UF_TLS, 1
