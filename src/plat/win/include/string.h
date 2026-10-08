/*
 * Minimal <string.h> shim for the freestanding Windows mbedTLS build.
 *
 * mbedTLS and the opcode glue call the C string functions directly; the
 * assembly corpus (src/base/str.s and the glue) defines them with opcode's
 * internal SysV-shaped ABI.  Declaring them with sysv_abi here makes every C
 * call agree with those definitions, so no MS-ABI memcpy wrapper is needed.
 * The file is only on the Windows build's include path; no MSVCRT is used.
 */
#ifndef OPCODE_WIN_STRING_H
#define OPCODE_WIN_STRING_H
#include <stddef.h>

#if defined(_WIN32) && (defined(__x86_64__) || defined(_M_X64))
#define OPCODE_SYSV __attribute__((sysv_abi))
#else
#define OPCODE_SYSV
#endif

#ifdef __cplusplus
extern "C" {
#endif

void *memcpy(void *dst, const void *src, size_t n) OPCODE_SYSV;
void *memmove(void *dst, const void *src, size_t n) OPCODE_SYSV;
void *memset(void *dst, int c, size_t n) OPCODE_SYSV;
int memcmp(const void *a, const void *b, size_t n) OPCODE_SYSV;
size_t strlen(const char *s) OPCODE_SYSV;
int strcmp(const char *a, const char *b) OPCODE_SYSV;
int strncmp(const char *a, const char *b, size_t n) OPCODE_SYSV;
char *strchr(const char *s, int c) OPCODE_SYSV;
char *strstr(const char *hay, const char *needle) OPCODE_SYSV;
char *strncpy(char *dst, const char *src, size_t n) OPCODE_SYSV;

/* mingw's <windows.h> (via stralign.h) parses inline bodies that call the
 * MSVCRT aliases below even when they are never emitted; declaring them keeps
 * the freestanding build warning-free without linking the CRT. */
int _wcsicmp(const wchar_t *a, const wchar_t *b);
int _wcsnicmp(const wchar_t *a, const wchar_t *b, size_t n);
int _stricmp(const char *a, const char *b);
int _strnicmp(const char *a, const char *b, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* OPCODE_WIN_STRING_H */
