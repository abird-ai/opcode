/*
 * example_c — minimal Opcode static plugin (M6), freestanding C, no libc.
 *
 * Built by the Makefile with -Dopcode_plugin_init=opcode_plugin_init_example_c
 * (the manifest name selects the link symbol).  The tool executes
 * synchronously and completes with host->tool_done; the result envelope is
 * allocated with host->alloc, so the host owns it after the call.
 */
#include "../../include/opcode_plugin.h"

#define OPCODE_EXAMPLE_VERSION "0.1.0"

/* No libc: tiny local string helpers (the plugin must not allocate outside
 * the host allocator, and must not call into libc at all). */
static unsigned long s_len(const char *s)
{
    unsigned long n = 0;
    while (s[n])
        n++;
    return n;
}

static void s_copy(char *dst, const char *src)
{
    while ((*dst++ = *src++))
        ;
}

static OPCODE_SYSV void hello_execute(const OpcodeHostV1 *host, uint64_t call,
                          const char *tool_call_id, const char *args_json,
                          const char *signal_token)
{
    static const char pre[] =
        "{\"content\":[{\"type\":\"text\",\"text\":\"hello ";
    static const char post[] = "\"}],\"is_error\":false}";
    const char *name = host->json_get_str(args_json, "name", "world");
    char *escaped = host->json_escape(name ? name : "world");
    unsigned long total;
    char *out;
    char *p;

    (void)tool_call_id;
    (void)signal_token;
    if (!escaped)
        escaped = host->strdup_("world");

    total = s_len(pre) + s_len(escaped) + s_len(post);
    out = (char *)host->alloc(total + 1);
    p = out;
    s_copy(p, pre);
    p += s_len(pre);
    s_copy(p, escaped);
    p += s_len(escaped);
    s_copy(p, post);

    host->free(escaped);
    host->tool_done(call, out, 0);
}

static const OpcodeToolV1 hello_tool = {
    sizeof(OpcodeToolV1),
    OPCODE_TOOL_READONLY,
    "hello",
    "hello",
    "Say hello to a person by name.",
    "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
    0, /* prompt_snippet */
    0, /* prompt_guidelines */
    hello_execute,
    0  /* update */
};

static OPCODE_SYSV int example_init(const OpcodeHostV1 *host)
{
    host->register_tool(&hello_tool);
    return 0;
}

OPCODE_SYSV int opcode_plugin_init(const OpcodeHostV1 *host, OpcodePluginV1 *out)
{
    out->abi_version = OPCODE_ABI_VERSION;
    out->struct_size = sizeof(OpcodePluginV1);
    out->name = "example_c";
    out->version = OPCODE_EXAMPLE_VERSION;
    out->init = example_init;
    out->shutdown = 0;
    return 0;  /* the host calls out->init(host) after the ABI check */
}
