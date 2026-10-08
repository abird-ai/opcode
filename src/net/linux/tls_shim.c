/*
 * Opcode Linux TLS backend: mbedTLS implementation of the tls_* contract
 * from src/net/net.inc.
 *
 * Copyright (c) 2026 Opcode contributors
 * SPDX-License-Identifier: MIT
 *
 * Build-time configuration lives in third_party/mbedtls_opcode_config.h; the
 * platform hooks (calloc/free, time, gmtime, snprintf, entropy) live in
 * third_party/mbedtls_glue.c.  No libc, no dynamic linking.
 *
 * Socket ownership: tls_new() creates the TLS state but no fd.  The caller
 * performs net_socket()/net_connect() itself, hands the fd over with
 * tls_set_fd(), and remains responsible for net_close().  tls_close() never
 * closes the fd.
 */
#include "tls_shim.h"

#include "mbedtls/build_info.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

/* Mirrors net.inc. */
#define OPCODE_TLS_VERIFY    1
#define OPCODE_TLS_INSECURE  2

#define OPCODE_EAGAIN        11
#define OPCODE_EACCES        13
#define OPCODE_EIO           5
#define OPCODE_EINVAL        22

/* Platform hooks provided by third_party/mbedtls_glue.c. */
extern void *opcode_calloc(size_t nmemb, size_t size);
extern void opcode_free(void *ptr);


/* Layer 1 socket API (src/net/linux/socket.s), SysV ABI.  The __asm__ labels
 * keep the Mach-O symbol names bare; see ADR-6 and third_party/mbedtls_glue.c. */
extern long net_send(int fd, const void *buf, unsigned long len)
    __asm__("net_send") OPCODE_SYSV;
extern long net_recv(int fd, void *buf, unsigned long len)
    __asm__("net_recv") OPCODE_SYSV;

/* CA bundle embedded by tools/gen-assets.sh from third_party/cacert.pem.  Bare
 * Mach-O symbol names again. */
extern const unsigned char opcode_cacert[] __asm__("opcode_cacert");
extern const unsigned char opcode_cacert_end[] __asm__("opcode_cacert_end");

/* The tls_* entry points are called from the translated assembly, which is
 * generated from one x86 description and must not be forked per platform.  A
 * Mach-O C compiler would give these definitions a leading underscore, so they
 * carry asm labels equal to the bare names the assembly references (ADR-6).
 * On Linux the label equals the C name and the object is unchanged. */
void *tls_new(const char *host, unsigned short port, long opts)
    __asm__("tls_new") OPCODE_SYSV;
int tls_set_fd(void *conn, int fd) __asm__("tls_set_fd") OPCODE_SYSV;
int tls_handshake(void *conn) __asm__("tls_handshake") OPCODE_SYSV;
int64_t tls_read(void *conn, void *buf, size_t len) __asm__("tls_read") OPCODE_SYSV;
int64_t tls_write(void *conn, const void *buf, size_t len) __asm__("tls_write") OPCODE_SYSV;
void tls_close(void *conn) __asm__("tls_close") OPCODE_SYSV;
size_t tls_pending(void *conn) __asm__("tls_pending") OPCODE_SYSV;
int64_t tls_want(void *conn) __asm__("tls_want") OPCODE_SYSV;
const char *tls_last_error(void *conn) __asm__("tls_last_error") OPCODE_SYSV;
int tls_fd(void *conn) __asm__("tls_fd") OPCODE_SYSV;

typedef struct opcode_tls_conn {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    int fd;
    int want;
    int net_errno;              /* last negative errno from net_send/recv */
    char err[512];
} opcode_tls_conn;

/* ------------------------------------------------------------ global state */
/* The trust store and the DRBG are process-wide and initialised on first use;
 * Opcode is single-threaded, so no locking is required. */
static mbedtls_x509_crt g_ca;
static mbedtls_entropy_context g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static int g_ready;
static char g_init_error[128];

static void set_error_mbedtls(opcode_tls_conn *c, int ret)
{
    static const char prefix[] = "TLS: ";
    char tmp[160];
    size_t i = 0;
    if (c == NULL) {
        return;
    }
    while (prefix[i] != '\0' && i + 1 < sizeof(c->err)) {
        c->err[i] = prefix[i];
        i++;
    }
    mbedtls_strerror(ret, tmp, sizeof(tmp));
    for (size_t j = 0; tmp[j] != '\0' && i + 1 < sizeof(c->err); j++) {
        c->err[i++] = tmp[j];
    }
    c->err[i] = '\0';
}

static int global_init(void)
{
    const unsigned char pers[] = "opcode-mbedtls";
    int ret;

    if (g_ready) {
        return 0;
    }

    opcode_platform_setup();

    mbedtls_x509_crt_init(&g_ca);
    ret = mbedtls_x509_crt_parse(&g_ca, opcode_cacert,
                                 (size_t) (opcode_cacert_end - opcode_cacert));
    if (ret != 0) {
        /* ret > 0 means "some certificates failed, but at least one parsed";
         * anything < 0 means the whole bundle is unusable. */
        if (ret < 0) {
            mbedtls_strerror(ret, g_init_error, sizeof(g_init_error));
            mbedtls_x509_crt_free(&g_ca);
            return -1;
        }
    }

    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_drbg);
    ret = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                                pers, sizeof(pers) - 1);
    if (ret != 0) {
        mbedtls_strerror(ret, g_init_error, sizeof(g_init_error));
        mbedtls_entropy_free(&g_entropy);
        mbedtls_ctr_drbg_free(&g_drbg);
        /* Release the already-parsed CA as well: a later retry calls
         * mbedtls_x509_crt_init/parse again and would otherwise leak the chain
         * (and double-append to it). */
        mbedtls_x509_crt_free(&g_ca);
        return -1;
    }

    g_ready = 1;
    return 0;
}

/* -------------------------------------------------------------- BIO hooks */
static int bio_send(void *ctx, const unsigned char *buf, size_t len)
{
    opcode_tls_conn *c = (opcode_tls_conn *) ctx;
    long n = net_send(c->fd, buf, (unsigned long) len);

    if (n >= 0) {
        return (int) n;
    }
    if (n == -OPCODE_EAGAIN) {
        return MBEDTLS_ERR_SSL_WANT_WRITE;
    }
    c->net_errno = (int) n;
    return MBEDTLS_ERR_NET_SEND_FAILED;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len)
{
    opcode_tls_conn *c = (opcode_tls_conn *) ctx;
    long n = net_recv(c->fd, buf, (unsigned long) len);

    if (n > 0) {
        return (int) n;
    }
    if (n == 0) {
        return 0;               /* EOF; mbedTLS converts it to CONN_EOF */
    }
    if (n == -OPCODE_EAGAIN) {
        return MBEDTLS_ERR_SSL_WANT_READ;
    }
    c->net_errno = (int) n;
    return MBEDTLS_ERR_NET_RECV_FAILED;
}

/* Translate an mbedTLS return code into the tls_* contract: 0 / n / -EAGAIN
 * / -errno.  want 1 = read, 2 = write. */
static int64_t map_result(opcode_tls_conn *c, int ret)
{
    if (ret == 0) {
        return 0;
    }
    if (ret > 0) {
        return ret;
    }
    switch (ret) {
    case MBEDTLS_ERR_SSL_WANT_READ:
        c->want = 1;
        return -OPCODE_EAGAIN;
    case MBEDTLS_ERR_SSL_WANT_WRITE:
        c->want = 2;
        return -OPCODE_EAGAIN;
    case MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY:
    case MBEDTLS_ERR_SSL_CONN_EOF:
        return 0;
    case MBEDTLS_ERR_NET_SEND_FAILED:
    case MBEDTLS_ERR_NET_RECV_FAILED:
    case MBEDTLS_ERR_NET_CONN_RESET:
        return c->net_errno != 0 ? c->net_errno : -OPCODE_EIO;
    default:
        set_error_mbedtls(c, ret);
        return -OPCODE_EIO;
    }
}

/* ------------------------------------------------------------ public API */
OPCODE_SYSV void *tls_new(const char *host, unsigned short port, long opts)
{
    opcode_tls_conn *c;
    int ret;

    (void) port;                /* SNI/hostname is what matters for the client */

    /* Certificate verification is only meaningful with a hostname to match; if
     * one is required and none was given, fail closed instead of verifying the
     * chain without checking the peer identity. */
    if (opts != OPCODE_TLS_INSECURE && host == NULL) {
        return NULL;
    }

    if (global_init() != 0) {
        return NULL;
    }

    c = (opcode_tls_conn *) opcode_calloc(1, sizeof(*c));
    if (c == NULL) {
        return NULL;
    }
    c->fd = -1;

    mbedtls_ssl_init(&c->ssl);
    mbedtls_ssl_config_init(&c->conf);

    ret = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        set_error_mbedtls(c, ret);
        goto fail;
    }

    mbedtls_ssl_conf_authmode(&c->conf, opts == OPCODE_TLS_INSECURE ?
                              MBEDTLS_SSL_VERIFY_NONE :
                              MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&c->conf, &g_ca, NULL);
    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &g_drbg);
    /* Keep TLS 1.2 as the floor; the preset enables 1.2 + 1.3. */
    mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);

    ret = mbedtls_ssl_setup(&c->ssl, &c->conf);
    if (ret != 0) {
        set_error_mbedtls(c, ret);
        goto fail;
    }

    if (host != NULL) {
        ret = mbedtls_ssl_set_hostname(&c->ssl, host);
        if (ret != 0) {
            set_error_mbedtls(c, ret);
            goto fail;
        }
    }

    mbedtls_ssl_set_bio(&c->ssl, c, bio_send, bio_recv, NULL);
    return c;

fail:
    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    opcode_free(c);
    return NULL;
}

OPCODE_SYSV int tls_set_fd(void *conn, int fd)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    if (c == NULL) {
        return -OPCODE_EINVAL;
    }
    c->fd = fd;
    return 0;
}

OPCODE_SYSV int tls_handshake(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    int ret;
    uint32_t flags;

    if (c == NULL || c->fd < 0) {
        return -OPCODE_EINVAL;
    }
    c->want = 0;
    c->net_errno = 0;

    ret = mbedtls_ssl_handshake(&c->ssl);
    if (ret == 0) {
        flags = mbedtls_ssl_get_verify_result(&c->ssl);
        if (flags != 0) {
            mbedtls_x509_crt_verify_info(c->err, sizeof(c->err), "TLS: ",
                                         flags);
            return -OPCODE_EACCES;
        }
        return 0;
    }
    if (ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
        flags = mbedtls_ssl_get_verify_result(&c->ssl);
        mbedtls_x509_crt_verify_info(c->err, sizeof(c->err), "TLS: ", flags);
        c->want = 0;
        return -OPCODE_EACCES;
    }
    return (int) map_result(c, ret);
}

OPCODE_SYSV int64_t tls_read(void *conn, void *buf, size_t len)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    int ret;

    if (c == NULL || c->fd < 0) {
        return -OPCODE_EINVAL;
    }
    c->want = 0;
    c->net_errno = 0;

    ret = mbedtls_ssl_read(&c->ssl, (unsigned char *) buf, len);
    return map_result(c, ret);
}

OPCODE_SYSV int64_t tls_write(void *conn, const void *buf, size_t len)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    int ret;

    if (c == NULL || c->fd < 0) {
        return -OPCODE_EINVAL;
    }
    c->want = 0;
    c->net_errno = 0;

    ret = mbedtls_ssl_write(&c->ssl, (const unsigned char *) buf, len);
    return map_result(c, ret);
}

OPCODE_SYSV void tls_close(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    if (c == NULL) {
        return;
    }
    mbedtls_ssl_free(&c->ssl);
    mbedtls_ssl_config_free(&c->conf);
    opcode_free(c);
}

OPCODE_SYSV size_t tls_pending(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    if (c == NULL) {
        return 0;
    }
    return (size_t) mbedtls_ssl_get_bytes_avail(&c->ssl);
}

OPCODE_SYSV int64_t tls_want(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    return c == NULL ? 0 : c->want;
}

OPCODE_SYSV const char *tls_last_error(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    if (c == NULL) {
        return NULL;
    }
    if (c->err[0] == '\0' && !g_ready && g_init_error[0] != '\0') {
        return g_init_error;
    }
    return c->err[0] != '\0' ? c->err : NULL;
}

OPCODE_SYSV int tls_fd(void *conn)
{
    opcode_tls_conn *c = (opcode_tls_conn *) conn;
    return c == NULL ? -1 : c->fd;
}
