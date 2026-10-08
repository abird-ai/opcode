/*
 * opcode_plugin.h — stable C ABI for Opcode native plugins (C, Rust, Zig, ...)
 *
 * ABI rules (do not break):
 *   - All structs are append-only. The host checks `struct_size`; new fields go at
 *     the end. `abi_version` changes only for removals or semantic changes.
 *   - Every `const char *` payload crossing this boundary is a NUL-terminated
 *     UTF-8 JSON string unless stated otherwise.
 *   - Memory returned to the host must come from host->alloc. Memory returned by
 *     the host is owned by the host and valid until the next main-loop iteration
 *     unless the function's comment says otherwise.
 *   - The host is single-threaded. Plugins may use threads, but any call into the
 *     host from a plugin thread must go through host->defer.
 *
 * A plugin is a shared library (or static object, for static builds) exporting
 * exactly one symbol:
 *
 *     int opcode_plugin_init(const OpcodeHostV1 *host, OpcodePluginV1 *out);
 *
 * Return 0 on success. `out` is pre-zeroed; fill abi_version, struct_size, name,
 * version, init and shutdown.
 */
#ifndef OPCODE_PLUGIN_H
#define OPCODE_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

/* The host calls plugin callbacks (and plugins call host functions) with
 * opcode's internal SysV-shaped convention; on Windows the compiler would
 * otherwise emit Microsoft x64 calls.  Empty on every other target. */
#if defined(_WIN32) && (defined(__x86_64__) || defined(_M_X64))
#define OPCODE_SYSV __attribute__((sysv_abi))
#else
#define OPCODE_SYSV
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define OPCODE_ABI_VERSION 1

/* Tool flags */
#define OPCODE_TOOL_READONLY    0x0001u
#define OPCODE_TOOL_SEQUENTIAL  0x0002u  /* forces the whole batch sequential */
#define OPCODE_TOOL_DESTRUCTIVE 0x0004u  /* UI may confirm; permission plugins care */
#define OPCODE_TOOL_HIDDEN      0x0008u  /* registered, not declared to the model */
#define OPCODE_TOOL_THREADSAFE  0x0010u  /* execute may call tool_done from another
                                            thread; the host serializes it */

typedef struct OpcodeHostV1 OpcodeHostV1;

/* ------------------------------------------------------------------ tools */

typedef struct OpcodeToolV1 {
    uint32_t struct_size;            /* = sizeof(OpcodeToolV1) */
    uint32_t flags;                  /* OPCODE_TOOL_* */
    const char *name;                /* [a-z0-9_:.-]+, <= 64 bytes, unique */
    const char *label;               /* short human label */
    const char *description;         /* model-facing; be precise */
    const char *parameters_json;     /* JSON Schema object (NUL-terminated) */
    const char *prompt_snippet;      /* optional one-line "Available tools" entry */
    const char *prompt_guidelines;   /* optional, newline-separated bullets */

    /*
     * Called on the main loop once per tool call after argument validation.
     * `call` is an opaque handle; it must be passed back to host->tool_done exactly
     * once. `args_json` is the validated arguments object. `signal_token` is an
     * opaque cancellation token: compare with host->is_cancelled().
     *
     * The plugin must not block the main loop. For long work, either use
     * host->defer + host->tool_done (thread-safe host calls), or mark the tool
     * OPCODE_TOOL_THREADSAFE and call tool_done from a worker thread.
     */
    void (*execute)(const OpcodeHostV1 *host, uint64_t call,
                    const char *tool_call_id, const char *args_json,
                    const char *signal_token) OPCODE_SYSV;

    /*
     * Optional: stream partial output to the UI. `partial_json` must be a JSON
     * object of the same shape as the final result (at minimum {"content":[...]}).
     */
    void (*update)(const OpcodeHostV1 *host, uint64_t call,
                   const char *partial_json) OPCODE_SYSV;
} OpcodeToolV1;

/* ------------------------------------------------------------------ events */

/*
 * Event handler. `payload_json` is a JSON object; see .agents/docs/extensibility.md.
 * Return value:
 *   0 = continue
 *   1 = handled/veto (meaningful for "tool_call" and "input")
 *   negative = error, logged and treated as 0
 */
typedef int (*OpcodeEventHandler)(void *userdata, const char *payload_json)
    OPCODE_SYSV;

/* ------------------------------------------------------------------- host */

struct OpcodeHostV1 {
    uint32_t abi_version;            /* == OPCODE_ABI_VERSION */
    uint32_t struct_size;

    /* memory — alloc zeroes, free(NULL) is a no-op */
    void  *(*alloc)(size_t n) OPCODE_SYSV;
    void   (*free)(void *p) OPCODE_SYSV;
    char  *(*strdup_)(const char *s) OPCODE_SYSV;

    /* logging: 0=debug 1=info 2=warn 3=error */
    void   (*log)(int level, const char *msg) OPCODE_SYSV;

    /* tool registration — valid during init or after session_start */
    void   (*register_tool)(const OpcodeToolV1 *tool) OPCODE_SYSV;

    /* completes a call started by OpcodeToolV1.execute; `result_json` shape:
     * {"content":[{"type":"text","text":"..."}],"is_error":false}
     * Owned by the host after the call. Call exactly once per call handle. */
    void   (*tool_done)(uint64_t call, const char *result_json, int is_error)
        OPCODE_SYSV;

    /* schedules fn(userdata) on the main loop; safe from any thread */
    void   (*defer)(const OpcodeHostV1 *host,
                    void (*fn)(void *userdata) OPCODE_SYSV,
                    void *userdata) OPCODE_SYSV;

    /* cancellation: returns 1 if the run containing `signal_token` was aborted */
    int    (*is_cancelled)(const OpcodeHostV1 *host, const char *signal_token)
        OPCODE_SYSV;

    /* events — handler runs on the main loop in registration order */
    void   (*on_event)(const char *event_name, OpcodeEventHandler handler,
                       void *userdata) OPCODE_SYSV;

    /* minimal JSON helpers (host allocator; NULL on missing/wrong type) */
    const char *(*json_get_str)(const char *json, const char *path,
                                const char *dflt) OPCODE_SYSV;
    long long   (*json_get_int)(const char *json, const char *path,
                                long long dflt) OPCODE_SYSV;
    int         (*json_get_bool)(const char *json, const char *path, int dflt)
        OPCODE_SYSV;
    char       *(*json_escape)(const char *s) OPCODE_SYSV;

    /* session */
    const char *(*cwd)(const OpcodeHostV1 *host) OPCODE_SYSV;
    const char *(*session_id)(const OpcodeHostV1 *host) OPCODE_SYSV;
    const char *(*session_file)(const OpcodeHostV1 *host) OPCODE_SYSV;
    /* appends a `custom` session entry; not part of the model context */
    void        (*append_entry)(const char *custom_type, const char *data_json)
        OPCODE_SYSV;
    /* read-only snapshot of the current system prompt */
    const char *(*system_prompt)(const OpcodeHostV1 *host) OPCODE_SYSV;

    /* UI — no-ops (or notifications) outside the TUI */
    void (*notify)(const char *message, int level) OPCODE_SYSV;
    void (*set_status)(const char *key, const char *text) OPCODE_SYSV;
    void (*set_title)(const char *title) OPCODE_SYSV;
    /* Registers a slash command; handler receives the argument string and must
     * return a JSON result or NULL. Runs on the main loop. */
    void (*register_command)(const char *name, const char *description,
                             char *(*handler)(const char *args) OPCODE_SYSV)
        OPCODE_SYSV;

    /* model control; return 1 on success */
    int  (*set_model)(const char *provider, const char *model) OPCODE_SYSV;
    void (*set_thinking_level)(const char *level) OPCODE_SYSV;

    /* outbound HTTP (async). Callback runs on the main loop; response body is
     * valid for the duration of the callback only. Returns a request id. */
    uint64_t (*http_request)(const OpcodeHostV1 *host,
                             const char *method, const char *url,
                             const char *headers_json, /* {"Name":"Value"} */
                             const char *body, uint64_t body_len,
                             void (*cb)(void *userdata, int status,
                                        const char *headers_json,
                                        const char *body, uint64_t body_len)
                                 OPCODE_SYSV,
                             void *userdata) OPCODE_SYSV;
    void (*http_cancel)(const OpcodeHostV1 *host, uint64_t request) OPCODE_SYSV;

    /* reserved for future use; must be zero/NULL */
    void *reserved[8];
};

/* ----------------------------------------------------------------- plugin */

typedef struct OpcodePluginV1 {
    uint32_t abi_version;    /* = OPCODE_ABI_VERSION */
    uint32_t struct_size;    /* = sizeof(OpcodePluginV1) */
    const char *name;
    const char *version;
    int  (*init)(const OpcodeHostV1 *host) OPCODE_SYSV; /* register tools/commands/events */
    void (*shutdown)(void) OPCODE_SYSV;                /* idempotent; may be NULL */
    void *reserved[4];
} OpcodePluginV1;

/* The only exported symbol. Must return 0 and fill *out. */
int opcode_plugin_init(const OpcodeHostV1 *host, OpcodePluginV1 *out) OPCODE_SYSV;

/* Event names (for host->on_event). Payloads documented in
 * .agents/docs/extensibility.md §3.3. */
#define OPCODE_EV_PROJECT_TRUST         "project_trust"
#define OPCODE_EV_RESOURCES_DISCOVER    "resources_discover"
#define OPCODE_EV_SESSION_START         "session_start"
#define OPCODE_EV_SESSION_SHUTDOWN      "session_shutdown"
#define OPCODE_EV_INPUT                 "input"
#define OPCODE_EV_BEFORE_AGENT_START    "before_agent_start"
#define OPCODE_EV_AGENT_START           "agent_start"
#define OPCODE_EV_AGENT_END             "agent_end"
#define OPCODE_EV_TURN_START            "turn_start"
#define OPCODE_EV_TURN_END              "turn_end"
#define OPCODE_EV_MESSAGE_START         "message_start"
#define OPCODE_EV_MESSAGE_UPDATE        "message_update"
#define OPCODE_EV_MESSAGE_END           "message_end"
#define OPCODE_EV_TOOL_CALL             "tool_call"        /* vetoable */
#define OPCODE_EV_TOOL_RESULT           "tool_result"
#define OPCODE_EV_TOOL_EXEC_START       "tool_execution_start"
#define OPCODE_EV_TOOL_EXEC_UPDATE      "tool_execution_update"
#define OPCODE_EV_TOOL_EXEC_END         "tool_execution_end"
#define OPCODE_EV_BEFORE_PROVIDER_REQ   "before_provider_request"
#define OPCODE_EV_AFTER_PROVIDER_RES    "after_provider_response"
#define OPCODE_EV_PROVIDER_STREAM       "provider_stream_event"
#define OPCODE_EV_MODEL_SELECT          "model_select"
#define OPCODE_EV_THINKING_SELECT       "thinking_level_change"
#define OPCODE_EV_MCP_SERVERS_CHANGE    "mcp_servers_change"

#ifdef __cplusplus
}
#endif

#endif /* OPCODE_PLUGIN_H */
