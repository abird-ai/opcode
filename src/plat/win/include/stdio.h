/*
 * Minimal stdio shim for the freestanding Windows mbedTLS build.
 *
 * The mingw-w64 <stdio.h> defines snprintf/vsnprintf as inline wrappers around
 * __mingw_* functions, which would collide with the opcode glue's own
 * implementations (the link has no MSVCRT).  This header shadows it on the
 * Windows build only and declares exactly what the compiled mbedTLS subset
 * needs: the FILE type and the snprintf family.  No MSVCRT function is called.
 */
#ifndef OPCODE_WIN_STDIO_H
#define OPCODE_WIN_STDIO_H
#include <stddef.h>
#include <stdarg.h>

typedef struct _OpcodeWinFILE FILE;

#ifdef __cplusplus
extern "C" {
#endif

int snprintf(char *s, size_t n, const char *fmt, ...);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);
int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int fputs(const char *s, FILE *f);
int fputc(int c, FILE *f);
FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
int fflush(FILE *f);

#ifdef __cplusplus
}
#endif

/* platform.c selects the MSVC secure variant when _TRUNCATE is visible (the
 * mingw corecrt.h defines it); map it back to the glue's conforming
 * vsnprintf so no MSVCRT symbol is referenced. */
#ifndef vsnprintf_s
#define vsnprintf_s(s, n, truncate, fmt, ap) vsnprintf((s), (n), (fmt), (ap))
#endif

#endif /* OPCODE_WIN_STDIO_H */
