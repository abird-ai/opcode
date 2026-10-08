# wire/http_client.inc: HC transport state, stage/flag values and API notes.
# Included by src/wire/http_client.s and every call site that embeds an HC.
#
# HC is caller-owned storage. It holds the parsed Url (same 64-byte layout as
# src/wire/url.s), the host/authority copies used for SNI and the Host header,
# the socket/TLS handles and the receive buffer the client reads into.
#
# Callers must keep an HC zeroed except for hc_init, which sets HC_fd = -1.
# A caller that does not use hc_connect (the agent state machine resolves and
# connects itself) calls hc_resolve_host/hc_socket_* directly and fills in
# HC_fd/HC_conn.

.equ HC_url,          0     # 64  Url
.equ HC_host,         64    # 520 host cstr for SNI (512 + pad)
.equ HC_authority,    584   # 528 "host[:port]" for the Host header
.equ HC_authlen,      1112  # 4
.equ HC_tls,          1116  # 4  1 when the scheme is https
.equ HC_flags,        1120  # 4  HC_F_*
.equ HC_stage,        1124  # 4  HC_STAGE_*: furthest step attempted
.equ HC_ip,           1128  # 4  memory-byte ipv4
.equ HC_fd,           1136  # 8  -1 when closed
.equ HC_conn,         1144  # 8  tls_* handle or 0
.equ HC_deadline,     1152  # 8  absolute deadline for absolute mode, else 0
.equ HC_recbuf,       1160  # 8
.equ HC_recbuf_cap,   1168  # 8
.equ HC_SIZE,         1176

# HC_flags
.equ HC_F_INSECURE,   1     # skip certificate verification (https only)

# HC_stage: set before each step so a failed hc_connect can be classified
.equ HC_STAGE_URL,        1
.equ HC_STAGE_RESOLVE,    2
.equ HC_STAGE_SOCKET,     3
.equ HC_STAGE_CONNECT,    4
.equ HC_STAGE_TLS,        5
.equ HC_STAGE_HANDSHAKE,  6

# hc_recv_loop flags: per-call-site error policy. The historical loops differ
# in how strictly they consult http_resp_error, so the policy stays explicit:
#
#   HCR_CHECK_FEED   http_resp_error after every body chunk -> -EINVAL
#   HCR_CHECK_DONE   http_resp_error when the parser completed -> -EINVAL
#   HCR_CHECK_EOF    http_resp_error after http_resp_eof -> -EINVAL
#   HCR_PROGRESS     a feed that consumed nothing and did not complete is
#                    -EINVAL (guards against a parser stuck in an error state)
#
# fetch/update/discover/oauth/agent keep their exact historical combinations.
.equ HCR_CHECK_FEED,  1
.equ HCR_CHECK_DONE,  2
.equ HCR_CHECK_EOF,   4
.equ HCR_PROGRESS,    8
.equ HCR_STRICT,      HCR_CHECK_FEED | HCR_CHECK_DONE | HCR_CHECK_EOF | HCR_PROGRESS
