#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# MIT License
#
# Copyright (c) 2026 Vlad Shvedov
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ---------------------------------------------------------------------------
# Vendored from rhun <https://github.com/vshvedov/rhun>, tools/arm64.py.
# Host-side only: the Python tool translates the x86-64 sources into AArch64;
# it is never part of the built binary.  Opcode's local modifications, all in
# this file, are:
#   - `.equ`/`.set` emit the value captured at parse time (the struct-layout
#     macros are otherwise re-evaluated against the final constant table); the
#     operands of data directives are captured the same way.
#   - a bare GNU as assignment `NAME = value` lowers to `.set NAME, value`.
#   - `.extern` is dropped (declaration-only) and `.weak sym` lowers to
#     `.weak_definition`/`.weak_reference` depending on whether this file
#     defines the symbol, since Mach-O has no bare `.weak`.
#   - label differences (`.equ NAME, end - start`, `NAME = . - start`) are
#     folded to numbers at translation time, since Mach-O refuses them as
#     immediates.  A folded difference whose span crosses alignment padding the
#     layout pass inserts before an unaligned `.quad` is rejected: the x86 build
#     does not add that padding, so the constant would silently differ between
#     the two builds.  This pointer-alignment divergence is the one to watch.
#   - `.align`/`.balign` are laid out and emitted through one byte-alignment
#     helper so the two passes cannot drift.
#   - `.rept`/`.endr` bodies are expanded at parse time, so the layout pass
#     still sees every byte.
#   - `leave` lowers to `mov rsp, rbp` followed by `pop rbp`.
#   - `--os {darwin,linux}` selects the output object format (`elf` is accepted
#     as an alias for `linux`; default/absent == darwin): linux mode emits GNU as
#     ELF syntax — `adrp`/`:lo12:` page relocations, bare `.weak`, and the ELF
#     section names as authored — where darwin mode emits Mach-O
#     `@PAGE`/`@PAGEOFF`, `.weak_definition`/`.weak_reference` and `__DATA`
#     section names.  The darwin output is byte-for-byte what it was before.
#   - `--aapcs-entry SYM[,SYM...]` names the C-facing boundary: the symbols the
#     C objects reference but do not define.  When this unit **defines** one,
#     the definition is a C-facing translated function and the translator emits
#     an AAPCS **entry stub** (below) for it; direct calls inside translated
#     code name the body `SYM.x86`.  Repeatable, comma-separated.
#   - `--aapcs-callee SYM[,SYM...]` is the call side: a direct `call SYM` gets
#     the `mov x8, x0` bridge only when `SYM` is a symbol the C objects define
#     (the Makefile derives it with `nm --defined-only`).  An indirect call
#     always gets the bridge; a direct asm-to-asm call gets nothing, exactly
#     like the pure x86 model.
# The upstream code after this notice is otherwise unchanged, so re-vendoring
# stays a clean diff.
# ---------------------------------------------------------------------------
# Translates rhun's x86-64 assembly (GNU as, Intel syntax) into AArch64 assembly for Apple silicon.
#   tools/arm64.py [--os {darwin,linux}] [--aapcs-entry SYM[,SYM...]]... [--aapcs-callee SYM[,SYM...]]... [-I DIR]... [-D SYM[=VAL]]... IN.s OUT.s
#
# The translation keeps the x86 machine model, so the sources stay the one description of rhun:
#   registers   rax x8, rcx x3, rdx x2, rbx x19, rsp x28, rbp x20, rsi x1, rdi x0,
#               r8 x4, r9 x5, r10 x6, r11 x7, r12-r15 x21-x24; xmm0-7 v0-7, xmm8-15 v16-23
#   temporaries x9-x17, v24-v31
#   stack       x28 is rsp: push, pop and call use it as x86 does, and call leaves the return
#               address there; bl/ret still pair up for the return predictor
#   flags       NZCV hold ZF SF OF directly and C holds the inverse of CF (AArch64 subtraction
#               sense), so cmp/sub map one to one; flags are produced only where they are read
#   syscall     bl x_syscall (Linux numbers; src/plat/mac/sys.s provides them)
#   rep movsb, rep stosb/stosd, repe cmpsb, repne scasb and 128-bit div call helpers in src/plat/mac/rt.s
# Registers map so that rdi rsi rdx rcx r8 r9 are x0-x5 and rbx rbp r12-r15 rsp are callee-saved:
# translated functions are AAPCS functions that pop their return address from x28 and return in x8.
#
# C boundaries (ADR-112): the boundary is the *linked objects*, not the call syntax.  A
# `mov x8, x0` after an x86 `call` moves an AAPCS result out of x0 into rax (asm -> C), so it is
# emitted only for a direct call to a symbol the C objects define (`--aapcs-callee`), and always
# for an indirect call (the target is unknown; a C function pointer is the realistic case).
#
# The reverse (C -> asm) cannot be a `mov` at all: a translated function models x86 `call`/`ret`
# with the x86 stack in x28 (the caller pushes a return label, the epilogue does
# `ldr x30, [x28], #8; ret`), but a C caller arrives through AAPCS `bl`/x30 and pushes nothing on
# x28, so the epilogue would pop a stale label.  Each `--aapcs-entry` symbol this unit defines is
# therefore emitted twice: the translated body under the global `SYM.x86`, and `SYM` itself as a
# small native **entry stub** that saves the C x30, pushes a resume label on x28 exactly as an x86
# `call` would, enters the body, publishes the x86 result (x8) in the AAPCS register (x0) on
# resume, restores x30 and `ret`s to C.  A translated direct call to `SYM` is rewritten to
# `SYM.x86` so it stays on the pure x86 model (a stub entered from a translated caller would
# strand the caller's own pushed return label on x28).  Address-taken `.quad SYM` resolves to the
# stub, which is what makes a C function pointer to it work.
#
# ADR-109's in-unit address-escape `mov x0, x8` before `ret` is kept for the remaining functions
# (an asm `call [mem]`/`call reg` reads the result out of x0), but a C-facing body no longer needs
# it: the stub publishes x0, and the body itself must keep x0 (rdi) intact for translated direct
# callers.  Every other translated function keeps the x86 model exactly — `ret` must not touch
# x0 (rdi): opcode's assembly relies on argument registers surviving its own internal calls.

import os
import re
import resource
import sys
import threading
import time

# ---------------------------------------------------------------- registers

ARM = {'rax': 8, 'rcx': 3, 'rdx': 2, 'rbx': 19, 'rsp': 28, 'rbp': 20, 'rsi': 1, 'rdi': 0,
       'r8': 4, 'r9': 5, 'r10': 6, 'r11': 7, 'r12': 21, 'r13': 22, 'r14': 23, 'r15': 24}
REGS = {}   # name -> (arm index, bits, high byte)
for base, (r32, r16, r8, rh) in {
        'rax': ('eax', 'ax', 'al', 'ah'), 'rcx': ('ecx', 'cx', 'cl', 'ch'),
        'rdx': ('edx', 'dx', 'dl', 'dh'), 'rbx': ('ebx', 'bx', 'bl', 'bh'),
        'rsp': ('esp', 'sp', 'spl', None), 'rbp': ('ebp', 'bp', 'bpl', None),
        'rsi': ('esi', 'si', 'sil', None), 'rdi': ('edi', 'di', 'dil', None)}.items():
    i = ARM[base]
    REGS[base] = (i, 64, False)
    REGS[r32] = (i, 32, False)
    REGS[r16] = (i, 16, False)
    REGS[r8] = (i, 8, False)
    if rh:
        REGS[rh] = (i, 8, True)
for k in range(8, 16):
    i = ARM['r%d' % k]
    REGS['r%d' % k] = (i, 64, False)
    REGS['r%dd' % k] = (i, 32, False)
    REGS['r%dw' % k] = (i, 16, False)
    REGS['r%db' % k] = (i, 8, False)
    REGS['r%dl' % k] = (i, 8, False)
XMM = {'xmm%d' % k: (k if k < 8 else k + 8) for k in range(16)}

SIZE_PTR = {'byte': 8, 'word': 16, 'dword': 32, 'qword': 64, 'xmmword': 128, 'oword': 128}

CC = {'e': 'eq', 'z': 'eq', 'ne': 'ne', 'nz': 'ne', 'b': 'lo', 'c': 'lo', 'nae': 'lo',
      'ae': 'hs', 'nb': 'hs', 'nc': 'hs', 'a': 'hi', 'nbe': 'hi', 'be': 'ls', 'na': 'ls',
      'l': 'lt', 'nge': 'lt', 'ge': 'ge', 'nl': 'ge', 'g': 'gt', 'nle': 'gt', 'le': 'le',
      'ng': 'le', 's': 'mi', 'ns': 'pl', 'o': 'vs', 'no': 'vc'}
INVERSE = {'eq': 'ne', 'ne': 'eq', 'lo': 'hs', 'hs': 'lo', 'hi': 'ls', 'ls': 'hi', 'lt': 'ge', 'ge': 'lt',
           'gt': 'le', 'le': 'gt', 'mi': 'pl', 'pl': 'mi', 'vs': 'vc', 'vc': 'vs'}
CC_READS = {'eq': 'Z', 'ne': 'Z', 'lo': 'C', 'hs': 'C', 'hi': 'CZ', 'ls': 'CZ', 'lt': 'NV',
            'ge': 'NV', 'gt': 'ZNV', 'le': 'ZNV', 'mi': 'N', 'pl': 'N', 'vs': 'V', 'vc': 'V'}
ALL = frozenset('ZNCV')


class Error(Exception):
    pass


def rn(i, bits):
    if i == 31:
        return 'xzr' if bits == 64 else 'wzr'
    return ('x%d' if bits == 64 else 'w%d') % i


# ---------------------------------------------------------------- expressions

TOK = re.compile(r"\s*(?:(0[xX][0-9a-fA-F]+|0[bB][01]+|\d+[fb]?)|('\\?.'?)|([A-Za-z_.$][\w.$]*)|(<<|>>|==|!=|<>|<=|>=|&&|\|\||[-+*/%|&^~!()<>]))")


def tokenize(s):
    out, p = [], 0
    s = s.rstrip()
    while p < len(s):
        m = TOK.match(s, p)
        if not m or m.end() == p:
            raise Error('bad expression: %r' % s)
        num, ch, name, op = m.groups()
        if num is not None:
            out.append(('num', num))
        elif ch is not None:
            out.append(('chr', ch))
        elif name is not None:
            out.append(('name', name))
        else:
            out.append(('op', op))
        p = m.end()
    return out


# GNU as precedence: * / % << >>, then | & ^ !, then + - comparisons, then && ||
PREC = {'*': 4, '/': 4, '%': 4, '<<': 4, '>>': 4, '|': 3, '&': 3, '^': 3, '!': 3,
        '+': 2, '-': 2, '==': 2, '!=': 2, '<>': 2, '<': 2, '>': 2, '<=': 2, '>=': 2,
        '&&': 1, '||': 1}


class Unknown(Exception):
    pass


def char_value(c):
    body = c[1:]
    if body.endswith("'") and len(body) > 1:
        body = body[:-1]
    if body.startswith('\\'):
        e = body[1:]
        return {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, "'": 39, '"': 34}.get(e, ord(e[0]))
    return ord(body)


def evaluate(s, lookup):
    """Value of a constant expression or raise Unknown."""
    toks = tokenize(s)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def primary():
        t = peek()
        if t is None:
            raise Error('bad expression: %r' % s)
        pos[0] += 1
        kind, v = t
        if kind == 'num':
            if v[-1] in 'fb' and not v.lower().startswith('0x') and not v.lower().startswith('0b'):
                return lookup(v)
            if v.lower().startswith('0x'):
                return int(v, 16)
            if v.lower().startswith('0b'):
                return int(v[2:], 2)
            if len(v) > 1 and v[0] == '0':
                return int(v, 8)
            return int(v)
        if kind == 'chr':
            return char_value(v)
        if kind == 'name':
            return lookup(v)
        if v == '(':
            x = expr(0)
            if peek() != ('op', ')'):
                raise Error('missing ) in %r' % s)
            pos[0] += 1
            return x
        if v == '-':
            return -primary()
        if v == '+':
            return primary()
        if v == '~':
            return ~primary()
        if v == '!':
            return int(not primary())
        raise Error('bad expression: %r' % s)

    def expr(minp):
        x = primary()
        while True:
            t = peek()
            if t is None or t[0] != 'op' or t[1] not in PREC or PREC[t[1]] < minp:
                return x
            op = t[1]
            p = PREC[op]
            pos[0] += 1
            y = expr(p + 1)
            if op == '*':
                x = x * y
            elif op == '/':
                x = int(x / y) if y else 0
            elif op == '%':
                x = x - int(x / y) * y if y else 0
            elif op == '<<':
                x = x << y
            elif op == '>>':
                x = x >> y
            elif op == '|':
                x = x | y
            elif op == '&':
                x = x & y
            elif op == '^':
                x = x ^ y
            elif op == '!':
                x = x | ~y
            elif op == '+':
                x = x + y
            elif op == '-':
                x = x - y
            elif op == '==':
                x = -int(x == y)
            elif op in ('!=', '<>'):
                x = -int(x != y)
            elif op == '<':
                x = -int(x < y)
            elif op == '>':
                x = -int(x > y)
            elif op == '<=':
                x = -int(x <= y)
            elif op == '>=':
                x = -int(x >= y)
            elif op == '&&':
                x = int(bool(x) and bool(y))
            elif op == '||':
                x = int(bool(x) or bool(y))

    v = expr(0)
    if pos[0] != len(toks):
        raise Error('bad expression: %r' % s)
    return v


# ---------------------------------------------------------------- source reading

def split_statements(line):
    """Strips the comment; splits on ';'. Keeps strings and char literals intact."""
    out, cur, i, n = [], [], 0, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 2 if line[j] == '\\' else 1
            cur.append(line[i:j + 1])
            i = j + 1
            continue
        if c == "'":
            # 'x', '\n' or GNU 'x
            if i + 1 < n and line[i + 1] == '\\':
                j = i + 3
            else:
                j = i + 2
            if j < n and line[j] == "'":
                j += 1
            cur.append(line[i:j])
            i = j
            continue
        if c == '#':
            break
        if c == ';':
            out.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    out.append(''.join(cur))
    return [s for s in (x.strip() for x in out) if s]


def split_args(s):
    """Splits on top-level commas (not inside quotes, brackets or parentheses)."""
    out, cur, depth, i, n = [], [], 0, 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            cur.append(s[i:j + 1])
            i = j + 1
            continue
        if c == "'":
            j = i + 3 if (i + 1 < n and s[i + 1] == '\\') else i + 2
            if j < n and s[j] == "'":
                j += 1
            cur.append(s[i:j])
            i = j
            continue
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
        elif c == ',' and depth == 0:
            out.append(''.join(cur).strip())
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    last = ''.join(cur).strip()
    if last or out:
        out.append(last)
    return out


def string_bytes(lit):
    """bytes of a GNU as string literal"""
    t = lit.strip()[1:-1]
    out = bytearray()
    i = 0
    while i < len(t):
        c = t[i]
        if c != '\\':
            out += c.encode()
            i += 1
            continue
        e = t[i + 1]
        if e in '01234567':
            j = i + 1
            while j < len(t) and j < i + 4 and t[j] in '01234567':
                j += 1
            out.append(int(t[i + 1:j], 8) & 255)
            i = j
            continue
        if e == 'x':
            j = i + 2
            while j < len(t) and t[j] in '0123456789abcdefABCDEF':
                j += 1
            out.append(int(t[i + 2:j], 16) & 255)
            i = j
            continue
        out.append({'n': 10, 't': 9, 'r': 13, 'b': 8, 'f': 12, 'v': 11, 'a': 7, 'e': 27}.get(e, ord(e)))
        i += 2
    return bytes(out)


LABEL = re.compile(r'^([A-Za-z_.$][\w.$]*|\d+):(?!:)\s*')


class Stmt:
    def __init__(self, kind, text, origin, name=None, args=None, value=None, expr=None, values=None):
        self.kind = kind      # 'label', 'dir', 'ins'
        self.text = text
        self.origin = origin  # (file, line)
        self.name = name      # label name / directive / mnemonic
        self.args = args      # operand strings
        self.value = value    # value of a .set/.equ NAME at parse time
        self.expr = expr      # its expression when it was unresolved at parse time
        self.values = values  # parse-time values of a data directive's operands


class Macro:
    def __init__(self, name, params, body):
        self.name = name
        self.params = params  # [(name, default)]
        self.body = body      # [(text, origin)]


class Source:
    """Reads a file with includes, macros and conditionals into statements."""

    def __init__(self, incdirs, defines):
        self.incdirs = incdirs
        self.macros = {}
        self.consts = {}      # evaluated .equ/.set
        self.lazy = {}        # .equ with forward references
        self.stmts = []
        for k, v in defines.items():
            self.consts[k] = v
        self.counter = 0

    def lookup(self, name):
        if name in self.consts:
            return self.consts[name]
        if name in self.lazy:
            v = evaluate(self.lazy[name], self.lookup)
            self.consts[name] = v
            self.lazy.pop(name, None)
            return v
        raise Unknown(name)

    def value(self, s):
        try:
            return evaluate(s, self.lookup)
        except Unknown:
            return None

    DATA_CONST = frozenset(('.byte', '.short', '.value', '.word', '.hword', '.long', '.int', '.quad'))

    def data_values(self, d, args):
        """parse-time value of each operand of a constant data directive, so the emit path does
        not see a name that a later .set reassigns"""
        if d not in self.DATA_CONST:
            return None
        return [self.value(x) for x in split_args(args)]

    def read_file(self, path):
        with open(path) as f:
            text = f.read()
        return [(line, (path, n + 1)) for n, line in enumerate(text.split('\n'))]

    def find_include(self, name, cur):
        for d in [os.path.dirname(cur)] + self.incdirs:
            p = os.path.join(d, name)
            if os.path.exists(p):
                return p
        raise Error('include not found: %s' % name)

    def run(self, path):
        self.process(self.read_file(path), None)

    def process(self, lines, call_origin):
        i = 0
        cond = []   # stack of [active, taken]
        while i < len(lines):
            raw, origin = lines[i]
            i += 1
            where = call_origin or origin
            for st in split_statements(raw):
                active = all(c[0] for c in cond)
                word = st.split(None, 1)[0] if st else ''
                lw = word.lower()
                # conditionals are tracked even when inactive
                if lw in ('.if', '.ifdef', '.ifndef', '.ifne', '.ifeq', '.ifc', '.ifnc'):
                    if not active:
                        cond.append([False, True])
                        continue
                    rest = st[len(word):].strip()
                    if lw == '.ifdef':
                        v = rest in self.consts or rest in self.lazy
                    elif lw == '.ifndef':
                        v = not (rest in self.consts or rest in self.lazy)
                    elif lw in ('.ifc', '.ifnc'):
                        a, _, b = rest.partition(',')
                        v = (a.strip().strip("'\"") == b.strip().strip("'\"")) == (lw == '.ifc')
                    elif lw == '.ifeq':
                        v = evaluate(rest, self.lookup) == 0
                    else:
                        v = evaluate(rest, self.lookup) != 0
                    cond.append([v, v])
                    continue
                if lw == '.else':
                    c = cond[-1]
                    c[0] = not c[1]
                    c[1] = True
                    continue
                if lw == '.endif':
                    cond.pop()
                    continue
                if not active:
                    continue
                if lw == '.macro':
                    rest = st[len(word):].strip()
                    parts = rest.replace(',', ' ').split()
                    name = parts[0]
                    params = []
                    for p in parts[1:]:
                        if '=' in p:
                            a, b = p.split('=', 1)
                            params.append((a, b))
                        else:
                            params.append((p, ''))
                    body = []
                    depth = 1
                    while i < len(lines):
                        braw, borigin = lines[i]
                        i += 1
                        bw = braw.strip().split(None, 1)[0].lower() if braw.strip() else ''
                        if bw == '.macro':
                            depth += 1
                        if bw == '.endm':
                            depth -= 1
                            if depth == 0:
                                break
                        body.append((braw, borigin))
                    self.macros[name] = Macro(name, params, body)
                    continue
                if lw == '.include':
                    name = st[len(word):].strip().strip('"')
                    p = self.find_include(name, origin[0])
                    self.process(self.read_file(p), call_origin)
                    continue
                if lw == '.rept':
                    n = evaluate(st[len(word):].strip(), self.lookup)
                    body = []
                    depth = 1
                    while i < len(lines):
                        braw, borigin = lines[i]
                        i += 1
                        bw = braw.strip().split(None, 1)[0].lower() if braw.strip() else ''
                        if bw == '.rept':
                            depth += 1
                        if bw == '.endr':
                            depth -= 1
                            if depth == 0:
                                break
                        body.append((braw, borigin))
                    self.process(body * n, call_origin)
                    continue
                self.statement(st, where)

    def expand(self, m, argtext, where):
        args = split_args(argtext) if argtext.strip() else []
        vals = {}
        kw = {}
        pos = []
        for a in args:
            mm = re.match(r'^([A-Za-z_]\w*)\s*=(.*)$', a)
            if mm and any(p[0] == mm.group(1) for p in m.params):
                kw[mm.group(1)] = mm.group(2).strip()
            else:
                pos.append(a)
        for k, (pname, default) in enumerate(m.params):
            if pname in kw:
                v = kw[pname]
            elif k < len(pos):
                v = pos[k]
            else:
                v = default
            if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
                v = v[1:-1]
            vals[pname] = v
        self.counter += 1
        out = []
        names = sorted(vals, key=len, reverse=True)
        for line, origin in m.body:
            s = line
            s = s.replace('\\@', str(self.counter))
            for pname in names:
                s = re.sub(r'\\' + re.escape(pname) + r'(?![\w])', lambda _m, v=vals[pname]: v, s)
            s = s.replace('\\()', '')
            out.append((s, origin))
        self.process(out, where)

    def statement(self, st, where):
        while True:
            m = LABEL.match(st)
            if not m:
                break
            self.stmts.append(Stmt('label', m.group(1), where, name=m.group(1)))
            st = st[m.end():]
        if not st:
            return
        parts = st.split(None, 1)
        word = parts[0]
        rest = parts[1] if len(parts) > 1 else ''
        if word in self.macros:
            self.expand(self.macros[word], rest, where)
            return
        m = re.match(r'^([A-Za-z_.$][\w.$]*)\s*=\s*(.+)$', st)
        if m:
            # bare GNU as assignment NAME = value; emit a foldable .set
            name, expr = m.group(1), m.group(2).strip()
            val = None
            try:
                val = evaluate(expr, self.lookup)
                self.consts[name] = val
                self.lazy.pop(name, None)
            except Unknown:
                self.lazy[name] = expr
                self.consts.pop(name, None)
            self.stmts.append(Stmt('dir', st, where, name='.set', args='%s, %s' % (name, expr),
                                  value=val, expr=expr))
            return
        if word.startswith('.'):
            lw = word.lower()
            if lw in ('.equ', '.set'):
                name, expr = [x.strip() for x in rest.split(',', 1)]
                val = None
                try:
                    val = evaluate(expr, self.lookup)
                    self.consts[name] = val
                    self.lazy.pop(name, None)
                except Unknown:
                    self.lazy[name] = expr
                    self.consts.pop(name, None)
                self.stmts.append(Stmt('dir', st, where, name=lw, args=rest, value=val, expr=expr))
                return
            self.stmts.append(Stmt('dir', st, where, name=lw, args=rest,
                                   values=self.data_values(lw, rest)))
            return
        # instruction, with prefixes folded into the mnemonic
        mn = word.lower()
        if mn in ('rep', 'repe', 'repz', 'repne', 'repnz', 'lock'):
            p2 = rest.split(None, 1)
            mn = mn + ' ' + p2[0].lower()
            rest = p2[1] if len(p2) > 1 else ''
        self.stmts.append(Stmt('ins', st, where, name=mn, args=split_args(rest) if rest.strip() else []))


# ---------------------------------------------------------------- operands

class Reg:
    def __init__(self, name):
        self.name = name
        self.i, self.bits, self.high = REGS[name]


class Xmm:
    def __init__(self, name):
        self.name = name
        self.i = XMM[name]
        self.bits = None


class Imm:
    def __init__(self, text, value):
        self.text = text
        self.value = value    # None when it is a label
        self.bits = None


class Mem:
    def __init__(self, bits, base, index, scale, disp, sym):
        self.bits = bits
        self.base = base      # Reg (64-bit) or None
        self.index = index
        self.scale = scale
        self.disp = disp
        self.sym = sym        # rip-relative symbol


def split_terms(s):
    """'a + b*4 - 8' -> [(1,'a'), (1,'b*4'), (-1,'8')] at the top level."""
    out, cur, depth, sign = [], [], 0, 1
    i = 0
    s = s.strip()
    while i < len(s):
        c = s[i]
        if c == "'":
            j = i + 3 if (i + 1 < len(s) and s[i + 1] == '\\') else i + 2
            if j < len(s) and s[j] == "'":
                j += 1
            cur.append(s[i:j])
            i = j
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        if depth == 0 and c in '+-':
            t = ''.join(cur).strip()
            if t:
                out.append((sign, t))
                sign = 1 if c == '+' else -1
            else:
                sign = sign * (1 if c == '+' else -1)
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    t = ''.join(cur).strip()
    if t:
        out.append((sign, t))
    return out


# ---------------------------------------------------------------- immediates

def logical_imm(v, bits):
    mask = (1 << bits) - 1
    v &= mask
    if v == 0 or v == mask:
        return False
    size = bits
    while size > 2:
        half = size // 2
        hm = (1 << half) - 1
        if (v & hm) != ((v >> half) & hm):
            break
        size = half
    em = (1 << size) - 1
    e = v & em
    rot = ((e << 1) | (e >> (size - 1))) & em
    return bin(e ^ rot).count('1') == 2


def arith_imm(v):
    return 0 <= v < 4096 or (0 <= v < (1 << 24) and v & 0xfff == 0)


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


# ---------------------------------------------------------------- translator

STRING_OPS = ('rep movsb', 'rep stosb', 'rep stosd', 'repe cmpsb', 'repz cmpsb', 'repne scasb',
              'repnz scasb', 'stosb', 'lodsb', 'movsb')


class Translator:
    def __init__(self, src, path, os='darwin', aapcs=(), callees=()):
        self.src = src
        self.path = path
        self.os = os
        self.aapcs = aapcs
        # C_CALLEES: symbols the C objects define.  A direct call to one is an
        # asm -> C crossing and needs the call-side bridge; a direct call to
        # anything else is asm -> asm and stays on the pure x86 model.
        self.callees = {self.ren(x) for x in callees if x.strip()}
        # C_BOUNDARY: the C-referenced names (ADR-112's --aapcs-entry).  A
        # definition of one of these in this unit is a C-facing translated
        # function (ADR-112's CALLBACKS): it is entered from C through an entry
        # stub and its translated direct callers name the body `SYM.x86`.
        self.c_boundary = {self.ren(x) for x in aapcs if x.strip()}
        self.stmts = src.stmts
        self.globals = set()
        for s in self.stmts:
            if s.kind == 'dir' and s.name in ('.globl', '.global'):
                for x in split_args(s.args):
                    self.globals.add(self.ren(x.strip()))
        self.out = []
        self.nlabel = 0
        self.df = False
        self.labels = {}      # name -> [positions]
        for k, s in enumerate(self.stmts):
            if s.kind == 'label':
                self.labels.setdefault(s.name, []).append(k)
        self.needs = {}       # stmt index -> set of flags to produce
        self.c_through = set()
        self.exports = {}     # ret position -> flags its callers read
        self.cur = 0
        self.layout()
        self.cur_fn = None       # .text function the rets below belong to
        # ADR-109 in-unit address-escape ret bridge, minus the C-facing
        # definitions: a callback body is entered through the stub (which
        # publishes x0) and must keep x0 (rdi) intact for its translated
        # direct callers, so it gets no `mov x0, x8` of its own.
        self.ret_bridge = self.collect_addr_taken() - self.c_boundary

    # ---- helpers
    def emit(self, s):
        self.out.append('    ' + s)

    def newlabel(self):
        self.nlabel += 1
        return 'Lx%d' % self.nlabel

    def body_name(self, tgt):
        """a direct branch to a C-facing translated definition targets its body
        (`SYM.x86`), never the entry stub: a translated caller has already
        pushed its return label on x28, which the body's `ret` must consume (the
        stub's own resume push would strand it)."""
        return tgt + '.x86' if tgt in self.c_boundary else tgt

    def emit_entry_stub(self, name):
        """AAPCS entry stub for a function C calls by name.  C arrives with its
        return address in x30 and expects the x86 result (rax/x8) back in x0.
        Save x30, push a resume label on x28 exactly as an x86 `call` would
        (8 bytes, so the body's frame arithmetic matches), enter the translated
        body, publish x8 -> x0 on resume, restore x30 and return to C."""
        res = self.newlabel()
        self.out.append('%s:' % name)
        self.emit('str x30, [sp, #-16]!')
        self.emit('adr x17, %s' % res)
        self.emit('str x17, [x28, #-8]!')
        self.emit('bl %s.x86' % name)
        self.out.append('%s:' % res)
        self.emit('mov x0, x8')
        self.emit('ldr x30, [sp], #16')
        self.emit('ret')

    def err(self, st, msg):
        raise Error('%s:%d: %s: %s' % (st.origin[0], st.origin[1], msg, st.text))

    def collect_addr_taken(self):
        """renamed symbols whose address is taken in this unit by a
        `lea reg, [rip + sym]` or a pointer-sized data item (`.quad sym` and
        friends; e.g. the host vtable).  Direct `call sym` does not take an
        address.  Cross-unit escapes (a `.quad` in another file, or a C object
        referencing the symbol by name) cannot be seen here: C names those via
        --aapcs-entry (c_boundary)."""
        taken = set()
        symre = re.compile(r'^[A-Za-z_.$][\w.$]*$')
        for st in self.stmts:
            if st.kind == 'ins' and st.name == 'lea':
                try:
                    o = self.operand(st.args[1], st)
                except Error:
                    continue    # the emission pass reports it properly
                if isinstance(o, Mem) and o.sym is not None:
                    taken.add(o.sym)
            elif st.kind == 'dir' and st.name in ('.quad', '.long', '.word', '.short', '.byte'):
                for x in split_args(st.args):
                    x = x.strip()
                    if symre.match(x) and self.value(x) is None:
                        taken.add(self.ren(x))
        return taken

    def ren(self, s):
        """.Lfoo -> Lfoo outside strings"""
        parts = re.split(r'("(?:\\.|[^"\\])*")', s)
        for k in range(0, len(parts), 2):
            parts[k] = re.sub(r'(?<![\w.$])\.L([\w.$]+)', r'L\1', parts[k])
        return ''.join(parts)

    def value(self, text):
        v = self.src.value(text)
        if v is None:
            try:
                v = evaluate(text, self.label_lookup)
            except Unknown:
                return None
            if abs(v) >= 1 << 40:
                return None
        return v

    def label_lookup(self, name):
        """data labels: section base + offset, so differences in one section are constants"""
        if name == '.':
            d = getattr(self, 'dot_at', {}).get(self.emit_k)
            if d is None:
                raise Unknown(name)
            return ((d[0] + 1) << 44) + d[1]
        if name in self.src.lazy:
            v = evaluate(self.src.lazy[name], self.label_lookup)
            self.src.consts[name] = v
            self.src.lazy.pop(name, None)
            return v
        try:
            return self.src.lookup(name)
        except Unknown:
            pass
        p = self.target(name, self.cur)
        if p is None or p not in self.data_off:
            raise Unknown(name)
        sec, off = self.data_off[p]
        return ((sec + 1) << 44) + off

    def label_lookup_raw(self, name):
        """like label_lookup but without the .quad alignment padding layout() inserts, used only
        to detect a folded constant that would differ between the x86 and arm64 builds"""
        if name == '.':
            d = getattr(self, 'dot_raw', {}).get(self.emit_k)
            if d is None:
                raise Unknown(name)
            return ((d[0] + 1) << 44) + d[1]
        if name in self.src.lazy:
            return evaluate(self.src.lazy[name], self.label_lookup_raw)
        try:
            return self.src.consts[name]
        except KeyError:
            pass
        p = self.target(name, self.cur)
        if p is None or p not in self.raw_off:
            raise Unknown(name)
        sec, off = self.raw_off[p]
        return ((sec + 1) << 44) + off

    def raw_value(self, text):
        try:
            v = evaluate(text, self.label_lookup_raw)
        except Unknown:
            return None
        return None if abs(v) >= 1 << 40 else v

    def balign(self, a):
        """byte alignment of an `.align`/`.balign` directive (GNU as counts bytes, .p2align bits)"""
        return self.value(split_args(a)[0])

    @staticmethod
    def align_up(o, al):
        return (o + al - 1) // al * al

    def layout(self):
        """offsets of labels in data sections (the translation keeps data sizes); .quad data is
        8-aligned here, as pointers must be for the dynamic linker: self.pad marks where"""
        self.data_off = {}
        self.raw_off = {}
        self.dot_at = {}
        self.dot_raw = {}
        self.pad = set()
        secs = {}
        cur = '.text'
        stack = []
        off = {}
        padtot = {}           # bytes of .quad padding so far, per section (excluded from raw_off)
        run = {}              # labels at the current offset, per section
        sizes = {'.byte': 1, '.short': 2, '.value': 2, '.word': 2, '.hword': 2, '.long': 4, '.int': 4,
                 '.quad': 8, '.float': 4, '.single': 4, '.double': 8}
        for k, st in enumerate(self.stmts):
            dot = off.get(cur)
            sec = secs.setdefault(cur, len(secs))
            self.dot_at[k] = (sec, dot) if dot is not None else None
            self.dot_raw[k] = (sec, dot - padtot.get(cur, 0)) if dot is not None else None
            if st.kind == 'label':
                if cur != '.text' and off.setdefault(cur, 0) is not None:
                    self.data_off[k] = (sec, off[cur])
                    self.raw_off[k] = (sec, off[cur] - padtot.get(cur, 0))
                    run.setdefault(cur, []).append(k)
                continue
            if st.kind == 'ins':
                off[cur] = None
                continue
            d, a = st.name, st.args
            if d in ('.text', '.data', '.bss'):
                cur = d
            elif d in ('.section', '.pushsection'):
                if d == '.pushsection':
                    stack.append(cur)
                try:
                    cur = self.section_for(a) or cur
                except Error:
                    pass
            elif d == '.popsection':
                cur = stack.pop()
            elif d in ('.globl', '.global', '.type', '.size', '.equ', '.set'):
                pass
            else:
                o = off.setdefault(cur, 0)
                labels = run.pop(cur, [])
                if o is None:
                    continue
                if d == '.quad' and o % 8:
                    self.pad.add(labels[0] if labels else k)
                    padded = (o + 7) & ~7
                    padtot[cur] = padtot.get(cur, 0) + padded - o
                    o = padded
                    for p in labels:
                        self.data_off[p] = (self.data_off[p][0], o)
                if d in sizes:
                    off[cur] = o + sizes[d] * len(split_args(a))
                elif d in ('.ascii', '.asciz', '.string'):
                    n = 0
                    for x in split_args(a):
                        n += len(string_bytes(x)) + (0 if d == '.ascii' else 1)
                    off[cur] = o + n
                elif d == '.fill':
                    fa = split_args(a)
                    cnt = self.src.value(fa[0])
                    size = self.src.value(fa[1]) if len(fa) > 1 else 1
                    off[cur] = None if cnt is None else o + cnt * (size or 1)
                elif d in ('.zero', '.skip', '.space'):
                    v = self.src.value(split_args(a)[0])
                    off[cur] = None if v is None else o + v
                elif d == '.p2align':
                    al = 1 << int(split_args(a)[0])
                    off[cur] = self.align_up(o, al)
                elif d in ('.align', '.balign'):
                    al = self.balign(a)
                    off[cur] = o if al is None else self.align_up(o, al)
                elif d == '.incbin':
                    fn = a.strip().strip('"')
                    off[cur] = o + os.path.getsize(fn) if os.path.exists(fn) else None
                else:
                    off[cur] = o

    # ---- operand parsing
    def operand(self, text, st):
        s = text.strip()
        bits = None
        m = re.match(r'^(byte|word|dword|qword|xmmword|oword)\s+ptr\s*(.*)$', s, re.I)
        if m:
            bits = SIZE_PTR[m.group(1).lower()]
            s = m.group(2).strip()
        if s.startswith('['):
            if not s.endswith(']'):
                self.err(st, 'bad memory operand')
            return self.mem(s[1:-1], bits, st)
        ls = s.lower()
        if ls in REGS:
            return Reg(ls)
        if ls in XMM:
            return Xmm(ls)
        return Imm(s, self.value(s))

    def mem(self, inner, bits, st):
        base = index = None
        scale = 1
        disp = 0
        sym = None
        rip = False
        for sign, t in split_terms(inner):
            tl = t.strip().lower()
            if tl == 'rip':
                rip = True
                continue
            if tl in REGS and REGS[tl][1] == 64:
                if base is None and sign > 0:
                    base = Reg(tl)
                elif index is None and sign > 0:
                    index = Reg(tl)
                else:
                    self.err(st, 'bad address')
                continue
            m = re.match(r'^(\w+)\s*\*\s*(.+)$', t) or re.match(r'^(.+?)\s*\*\s*(\w+)$', t)
            if m:
                a, b = m.group(1).strip(), m.group(2).strip()
                if a.lower() in REGS or b.lower() in REGS:
                    r, sc = (a, b) if a.lower() in REGS else (b, a)
                    if index is not None or sign < 0:
                        self.err(st, 'bad address')
                    index = Reg(r.lower())
                    scale = self.value(sc)
                    continue
            v = self.value(t)
            if v is None:
                if sym is None and sign > 0 and re.match(r'^[A-Za-z_.$][\w.$]*$|^\d+[fb]$', t.strip()):
                    sym = self.ren(t.strip())
                    continue
                self.err(st, 'cannot evaluate %r' % t)
            disp += sign * v
        if sym is not None and not rip:
            self.err(st, 'absolute address')
        if rip and (base is not None or index is not None):
            self.err(st, 'rip with registers')
        return Mem(bits, base, index, scale, disp, sym)

    def opsize(self, ops, st):
        for o in ops:
            if isinstance(o, Reg):
                return o.bits
        for o in ops:
            if isinstance(o, Mem) and o.bits:
                return o.bits
        self.err(st, 'operand size unknown')

    # ---- immediates
    def mov_imm(self, reg, v, bits):
        """reg = v (bits 32 or 64)"""
        mask = (1 << bits) - 1
        v &= mask
        chunks = [(v >> (16 * k)) & 0xffff for k in range(bits // 16)]
        nz = [k for k, c in enumerate(chunks) if c]
        nf = [k for k, c in enumerate(chunks) if c != 0xffff]
        if len(nz) <= 1 or len(nf) <= 1 or logical_imm(v, bits):
            self.emit('mov %s, #%d' % (reg, sext(v, bits) if len(nf) <= 1 and len(nz) > 1 else v))
            return
        if len(nf) < len(nz):
            first = nf[0]
            self.emit('movn %s, #%d, lsl #%d' % (reg, (~chunks[first]) & 0xffff, 16 * first))
            for k in nf[1:]:
                self.emit('movk %s, #%d, lsl #%d' % (reg, chunks[k], 16 * k))
        else:
            first = nz[0]
            self.emit('movz %s, #%d, lsl #%d' % (reg, chunks[first], 16 * first))
            for k in nz[1:]:
                self.emit('movk %s, #%d, lsl #%d' % (reg, chunks[k], 16 * k))

    def imm_reg(self, v, bits, tmp=12):
        """a register holding v; zero register for 0"""
        if v & ((1 << bits) - 1) == 0:
            return rn(31, bits)
        r = rn(tmp, bits)
        self.mov_imm(r, v, bits)
        return r

    # ---- addresses
    def base_disp(self, b, disp, nbytes):
        if disp == 0:
            return '[%s]' % b
        if disp % nbytes == 0 and 0 <= disp < 4096 * nbytes:
            return '[%s, #%d]' % (b, disp)
        if -256 <= disp < 256:
            return '[%s, #%d]' % (b, disp)
        t = 'x10' if b == 'x9' else 'x9'
        self.mov_imm(t, disp, 64)
        return '[%s, %s]' % (b, t)

    def addr(self, m, nbytes, regoff=True):
        """emits setup (x9, x10) and returns the AArch64 address operand"""
        if m.sym is not None:
            if self.os == 'linux':
                self.emit('adrp x9, %s' % m.sym)
                self.emit('add x9, x9, :lo12:%s' % m.sym)
            else:
                self.emit('adrp x9, %s@PAGE' % m.sym)
                self.emit('add x9, x9, %s@PAGEOFF' % m.sym)
            return self.base_disp('x9', m.disp, nbytes)
        if m.index is None:
            return self.base_disp(rn(m.base.i, 64), m.disp, nbytes)
        sh = {1: 0, 2: 1, 4: 2, 8: 3}[m.scale]
        xi = rn(m.index.i, 64)
        if m.base is None:
            self.emit('lsl x9, %s, #%d' % (xi, sh))
            return self.base_disp('x9', m.disp, nbytes)
        xb = rn(m.base.i, 64)
        if m.disp == 0 and regoff and (sh == 0 or (1 << sh) == nbytes):
            return '[%s, %s%s]' % (xb, xi, ', lsl #%d' % sh if sh else '')
        self.emit('add x9, %s, %s%s' % (xb, xi, ', lsl #%d' % sh if sh else ''))
        return self.base_disp('x9', m.disp, nbytes)

    def lea_into(self, d, m):
        """d = address of m (64-bit register name)"""
        if m.sym is not None:
            if self.os == 'linux':
                self.emit('adrp %s, %s' % (d, m.sym))
                self.emit('add %s, %s, :lo12:%s' % (d, d, m.sym))
            else:
                self.emit('adrp %s, %s@PAGE' % (d, m.sym))
                self.emit('add %s, %s, %s@PAGEOFF' % (d, d, m.sym))
            self.add_const(d, d, m.disp)
            return
        if m.index is None:
            self.add_const(d, rn(m.base.i, 64), m.disp)
            return
        sh = {1: 0, 2: 1, 4: 2, 8: 3}[m.scale]
        xi = rn(m.index.i, 64)
        if m.base is None:
            self.emit('lsl %s, %s, #%d' % (d, xi, sh))
        else:
            self.emit('add %s, %s, %s%s' % (d, rn(m.base.i, 64), xi, ', lsl #%d' % sh if sh else ''))
        self.add_const(d, d, m.disp)

    def add_const(self, d, s, v, bits=64, flags=False):
        suf = 's' if flags else ''
        if v == 0:
            if d != s:
                self.emit('mov %s, %s' % (d, s))
            return
        if arith_imm(v):
            self.emit('add%s %s, %s, #%d' % (suf, d, s, v))
        elif arith_imm(-v):
            self.emit('sub%s %s, %s, #%d' % (suf, d, s, -v))
        else:
            t = rn(10 if 'x9' in (d, s) or 'w9' in (d, s) else 9, bits)
            if t[1:] in (d[1:], s[1:]):
                t = rn(13, bits)
            self.mov_imm(t, v, bits)
            self.emit('add%s %s, %s, %s' % (suf, d, s, t))

    # ---- values
    LD = {8: 'ldrb', 16: 'ldrh', 32: 'ldr', 64: 'ldr'}
    ST = {8: 'strb', 16: 'strh', 32: 'str', 64: 'str'}

    def load(self, m, bits, tmp, a=None):
        """tmp (index) = zero-extended memory value; returns register name"""
        if a is None:
            a = self.addr(m, bits // 8)
        r = rn(tmp, 64 if bits == 64 else 32)
        self.emit('%s %s, %s' % (self.LD[bits], r, a))
        return r

    def store(self, reg_i, bits, a):
        r = rn(reg_i, 64 if bits == 64 else 32)
        self.emit('%s %s, %s' % (self.ST[bits], r, a))

    def get(self, o, bits, tmp, clean=False, a=None):
        """register name holding operand o (bits); 8/16-bit registers may carry high garbage unless clean"""
        if isinstance(o, Reg):
            if o.high:
                r = rn(tmp, 32)
                self.emit('ubfx %s, %s, #8, #8' % (r, rn(o.i, 32)))
                return r
            if bits >= 32:
                return rn(o.i, bits)
            if clean:
                r = rn(tmp, 32)
                self.emit('%s %s, %s' % ('uxtb' if bits == 8 else 'uxth', r, rn(o.i, 32)))
                return r
            return rn(o.i, 32)
        if isinstance(o, Imm):
            if o.value is None:
                raise Error('label as value: ' + o.text)
            v = o.value & ((1 << bits) - 1)
            return self.imm_reg(v, 64 if bits == 64 else 32, tmp)
        if isinstance(o, Mem):
            return self.load(o, bits, tmp, a)
        raise Error('bad operand')

    def put(self, o, bits, val, a=None):
        """o = val (register name holding the value in its low bits)"""
        vi = int(val[1:]) if val[1:].isdigit() else 31
        if isinstance(o, Reg):
            if o.high:
                self.emit('bfi %s, %s, #8, #8' % (rn(o.i, 64), rn(vi, 64)))
            elif bits == 64:
                if val != rn(o.i, 64):
                    self.emit('mov %s, %s' % (rn(o.i, 64), val))
            elif bits == 32:
                if val != rn(o.i, 32):
                    self.emit('mov %s, %s' % (rn(o.i, 32), rn(vi, 32)))
            else:
                self.emit('bfi %s, %s, #0, #%d' % (rn(o.i, 64), rn(vi, 64), bits))
            return
        if isinstance(o, Mem):
            if a is None:
                a = self.addr(o, bits // 8)
            self.store(vi, bits, a)
            return
        raise Error('bad destination')

    # ---- flags analysis
    def target(self, name, k):
        m = re.match(r'^(\d+)([fb])$', name)
        if m:
            lst = self.labels.get(m.group(1), [])
            if m.group(2) == 'f':
                c = [p for p in lst if p > k]
                return c[0] if c else None
            c = [p for p in lst if p < k]
            return c[-1] if c else None
        lst = self.labels.get(name)
        return lst[0] if lst else None

    def reads(self, st):
        mn = st.name
        if mn.startswith('j') and mn != 'jmp' and mn[1:] in CC:
            return set(CC_READS[CC[mn[1:]]])
        if mn.startswith('set') and mn[3:] in CC:
            return set(CC_READS[CC[mn[3:]]])
        if mn.startswith('cmov') and mn[4:] in CC:
            return set(CC_READS[CC[mn[4:]]])
        if mn in ('adc', 'sbb'):
            return {'C'}
        return set()

    WRITES_ALL = {'add', 'sub', 'cmp', 'and', 'or', 'xor', 'test', 'neg', 'adc', 'sbb', 'comiss',
                  'ucomiss', 'repe cmpsb', 'repz cmpsb', 'repne scasb', 'repnz scasb', 'shl', 'sal',
                  'shr', 'sar', 'div', 'idiv', 'mul', 'imul', 'bsr', 'bsf'}

    def writes(self, st):
        mn = st.name
        if mn in self.WRITES_ALL:
            return set(ALL)
        if mn in ('inc', 'dec'):
            return {'Z', 'N', 'V'}
        if mn in ('bt', 'bts', 'btr', 'btc', 'clc', 'stc'):
            return {'C'}
        if mn in ('rol', 'ror'):
            return {'C', 'V'}
        return set()

    def analyze(self):
        # local subroutines that return flags: their rets export what the callers read
        for k, st in enumerate(self.stmts):
            if st.kind == 'ins' and st.name in ('call', 'syscall'):
                need = self.scan(k, ALL, [])
                if need:
                    t = self.target(st.args[0].strip(), k) if st.name == 'call' else None
                    if t is None:
                        self.err(st, 'flags read after call')
                    self.mark_exports(t, need)
        for k, st in enumerate(self.stmts):
            if st.kind != 'ins':
                continue
            w = self.writes(st)
            if not w:
                continue
            through = []
            need = self.scan(k, w, through)
            self.needs[k] = need
            if 'C' in need:
                # an inc/dec the carry passes on its way to a read
                for p in set(through):
                    if 'C' in self.scan(p, {'C'}, []):
                        self.c_through.add(p)

    def mark_exports(self, start, flags):
        work = [start]
        seen = set()
        n = len(self.stmts)
        while work:
            p = work.pop()
            while p < n and p not in seen:
                seen.add(p)
                st = self.stmts[p]
                if st.kind != 'ins':
                    p += 1
                    continue
                mn = st.name
                if mn == 'ret':
                    self.exports[p] = self.exports.get(p, set()) | set(flags)
                    break
                if mn.startswith('j'):
                    tgt = st.args[0].strip() if st.args else ''
                    t = self.target(tgt, p) if re.match(r'^[\w.$]+$', tgt) else None
                    if mn == 'jmp':
                        if t is None:
                            break
                        p = t
                        continue
                    if t is not None:
                        work.append(t)
                p += 1

    def may_keep_flags(self, st):
        """writes flags only sometimes: string compares with rcx 0, shifts by cl 0"""
        if st.name in ('repe cmpsb', 'repz cmpsb', 'repne scasb', 'repnz scasb'):
            return True
        return st.name in ('shl', 'sal', 'shr', 'sar', 'rol', 'ror') and len(st.args) > 1 and \
            st.args[1].strip().lower() == 'cl'

    def scan(self, k, track, through):
        """flags that instructions after k read before they are written; inc/dec passed while the
        carry was still tracked go to through (on any path: analyze checks them)"""
        need = set()
        work = [(k + 1, frozenset(track))]
        seen = set()
        n = len(self.stmts)
        while work:
            p, tr = work.pop()
            while p < n and tr:
                if (p, tr) in seen:
                    break
                seen.add((p, tr))
                st = self.stmts[p]
                if st.kind != 'ins':
                    p += 1
                    continue
                r = self.reads(st) & tr
                if r:
                    need |= r
                mn = st.name
                if mn.startswith('j'):
                    tgt = st.args[0] if st.args else ''
                    t = self.target(tgt, p) if re.match(r'^[\w.$]+$', tgt) else None
                    if mn == 'jmp':
                        if t is None:
                            break
                        p = t
                        continue
                    if t is not None:
                        work.append((t, tr))
                    p += 1
                    continue
                if mn == 'ret' and p in self.exports:
                    need |= self.exports[p] & tr
                if mn in ('ret', 'call', 'syscall', 'ud2', 'hlt'):
                    break
                w = self.writes(st)
                if w and 'C' in tr and 'C' not in w:
                    through.append(p)
                if not self.may_keep_flags(st):
                    tr = tr - frozenset(w)
                p += 1
        return need

    # ---- main
    def run(self):
        self.analyze()
        out = self.out
        out.append('// translated from %s by tools/arm64.py' % self.path)
        out.append('.file 1 "%s"' % os.path.abspath(self.path))
        sect = '.text'
        stack = []
        self.seen_sections = set()
        for k, st in enumerate(self.stmts):
            self.emit_k = k
            if k in self.pad:
                out.append('.p2align 3')
            if st.kind == 'label':
                name = self.ren(st.name)
                if sect == '.text' and name in self.globals and name in self.c_boundary:
                    # A C-facing translated definition: expose the body under
                    # `SYM.x86` (what every translated direct call names) and
                    # define `SYM` as the AAPCS entry stub C's `bl SYM` reaches
                    # (and what an address-taken `.quad SYM` resolves to).
                    self.emit_entry_stub(name)
                    out.append('.globl %s.x86' % name)
                    out.append('%s.x86:' % name)
                    self.cur_fn = name
                    continue
                out.append('%s:' % name)
                if sect == '.text':
                    if name in self.ret_bridge or \
                            (not st.name.startswith('.') and not st.name[0].isdigit()):
                        self.cur_fn = name
                continue
            if st.kind == 'dir':
                r = self.directive(st, sect, stack)
                if r is not None:
                    sect = r
                continue
            self.cur = k
            if st.origin[0] == self.path:
                out.append('    .loc 1 %d 0' % st.origin[1])
            out.append('    // %s' % st.text)
            try:
                self.instruction(st, self.needs.get(k, set()), k)
            except Error as e:
                if str(e).startswith(st.origin[0]):
                    raise
                self.err(st, str(e))
        out.append('')
        return '\n'.join(out)

    SECT = {'.text': '.text', '.data': '.data', '.bss': '.bss'}

    def section_for(self, name):
        name = name.split(',')[0].strip().strip('"')
        if self.os == 'linux':
            # GNU as switches bare only on .text/.data/.bss; every other ELF
            # section name needs the explicit `.section` keyword.  The names
            # pass through as authored (the comma-split above keeps flags out).
            if name.startswith('.note'):
                return None
            return name if name in self.SECT else '.section ' + name
        # ELF sections stay apart: their contents must not interleave
        if name == '.rodata':
            return '.section __DATA,__const'
        if name.startswith('.rodata.str'):
            return '.section __DATA,__rodata_str'
        if name.startswith('.data'):
            return '.data'
        if name.startswith('.bss'):
            return '.bss'
        if name.startswith('.text'):
            return '.text'
        if name.startswith('.note'):
            return None
        raise Error('unknown section ' + name)

    def switch(self, s):
        """section directive; data sections start 8-aligned so pointers in them stay aligned"""
        self.out.append(s)
        if s != '.text' and s not in self.seen_sections:
            self.out.append('.p2align 3')
        self.seen_sections.add(s)
        return s

    def directive(self, st, sect, stack):
        d = st.name
        a = st.args
        out = self.out
        if d in self.SECT:
            return self.switch(self.SECT[d])
        if d == '.section':
            s = self.section_for(a)
            if s:
                return self.switch(s)
            return None
        if d == '.pushsection':
            stack.append(sect)
            return self.switch(self.section_for(a))
        if d == '.popsection':
            return self.switch(stack.pop())
        if d in ('.globl', '.global'):
            out.append('.globl %s' % self.ren(a))
            return None
        if d in ('.type', '.size', '.intel_syntax', '.att_syntax', '.ident', '.file', '.hidden', '.local',
                 '.extern'):
            return None
        if d == '.weak':
            name = a.strip().split(',')[0].strip()
            if self.os == 'linux':
                if name:
                    out.append('.weak %s' % self.ren(name))
            elif name and name in self.labels:
                out.append('.weak_definition %s' % self.ren(name))
            elif name:
                out.append('.weak_reference %s' % self.ren(name))
            return None
        if d == '.p2align':
            out.append('.p2align %s' % a)
            return None
        if d in ('.balign', '.align'):
            v = self.balign(a)
            out.append('.p2align %d' % (v.bit_length() - 1))
            return None
        if d in ('.equ', '.set'):
            name, expr = [x.strip() for x in a.split(',', 1)]
            expr = st.expr if st.expr is not None else expr
            v = st.value
            raw = self.raw_value(expr) if v is None else None
            if v is None:
                v = self.value(expr)
                if v is not None:
                    self.src.consts[name] = v
                    self.src.lazy.pop(name, None)
            if v is not None:
                if raw is not None and raw != v:
                    self.err(st, 'constant %s folds to %d but the label span crosses %d bytes of '
                             'pointer alignment added only on arm64 (x86 gives %d); keep the '
                             'difference away from the .quad' % (name, v, v - raw, raw))
                out.append('.set %s, %d' % (self.ren(name), v))
            else:
                out.append('.set %s, %s' % (self.ren(name), self.ren(expr)))
            return None
        size = {'.byte': '.byte', '.short': '.short', '.value': '.short', '.word': '.short', '.hword': '.short',
                '.long': '.long', '.int': '.long', '.quad': '.quad', '.float': '.float', '.single': '.float',
                '.double': '.double'}
        if d in size:
            items = []
            for i, x in enumerate(split_args(a)):
                v = st.values[i] if st.values and i < len(st.values) else None
                if v is None and d not in ('.float', '.single', '.double'):
                    v = self.value(x)
                items.append(str(v) if v is not None else self.ren(x))
            out.append('%s %s' % (size[d], ', '.join(items)))
            return None
        if d in ('.ascii', '.asciz', '.string'):
            out.append('%s %s' % ('.asciz' if d == '.string' else d, a))
            return None
        if d in ('.zero', '.skip', '.space'):
            args = split_args(a)
            v = self.value(args[0])
            if v is None:
                self.err(st, 'size unknown')
            fill = self.value(args[1]) if len(args) > 1 else 0
            out.append('.zero %d%s' % (v, ', %d' % fill if fill else ''))
            return None
        if d == '.fill':
            items = []
            for x in split_args(a):
                v = self.value(x)
                items.append(str(v) if v is not None else self.ren(x))
            out.append('.fill %s' % ', '.join(items))
            return None
        if d == '.incbin':
            out.append('.incbin %s' % a)
            return None
        self.err(st, 'unsupported directive')

    # ---- instructions
    def instruction(self, st, need, k):
        mn = st.name
        ops = [self.operand(x, st) for x in st.args] if mn not in ('call', 'jmp') and not mn.startswith('j') else None
        if mn.startswith('j') or mn == 'call':
            return self.branch(st, mn)
        if mn == 'ret':
            self.emit('ldr x30, [x28], #8')
            if self.cur_fn in self.ret_bridge:
                # address-taken by a `lea`/`.quad` in this unit but not C-facing:
                # an asm indirect caller reads the result out of x0, so publish
                # it here.  A C-facing body does not need this (its entry stub
                # publishes x0) and must not clobber x0 for its translated
                # direct callers; every other translated function keeps the x86
                # model exactly (ret must not touch x0/rdi).
                self.emit('mov x0, x8')
            self.emit('ret')
            return
        f = getattr(self, 'i_' + mn.replace(' ', '_'), None)
        if f is not None:
            return f(st, ops, need, k)
        if mn in ('add', 'sub', 'cmp', 'and', 'or', 'xor', 'test'):
            return self.alu(st, mn, ops, need)
        if mn.startswith('set') and mn[3:] in CC:
            cc = CC[mn[3:]]
            self.emit('cset w11, %s' % cc)
            self.put(ops[0], 8, 'w11')
            return
        if mn.startswith('cmov') and mn[4:] in CC:
            cc = CC[mn[4:]]
            d, s = ops
            bits = d.bits
            if bits < 32:
                self.err(st, 'narrow cmov')
            v = self.get(s, bits, 12)
            self.emit('csel %s, %s, %s, %s' % (rn(d.i, bits), v, rn(d.i, bits), cc))
            return
        if mn in ('shl', 'sal', 'shr', 'sar', 'rol', 'ror'):
            return self.shift(st, mn, ops, need)
        self.err(st, 'unsupported instruction')

    def branch(self, st, mn):
        t = st.args[0].strip() if st.args else ''
        direct = re.match(r'^[A-Za-z_.$][\w.$]*$|^\d+[fb]$', t) and t.lower() not in REGS
        if mn == 'jmp':
            if direct:
                self.emit('b %s' % self.body_name(self.ren(t)))
            else:
                self.emit('br %s' % self.target_reg(t, st))
            return
        if mn == 'call':
            if direct:
                tgt = self.ren(t)
                l = self.newlabel()
                self.emit('adr x17, %s' % l)
                self.emit('str x17, [x28, #-8]!')
                self.emit('bl %s' % self.body_name(tgt))
                if tgt in self.callees:
                    # asm -> C: the C callee returns in x0, so rax must be
                    # reloaded from it.  A translated callee returns in x8
                    # (rax) already and the label below is where it lands, so
                    # no bridge is emitted for it.
                    self.emit('mov x8, x0')
                self.out.append('%s:' % l)
            else:
                r = self.target_reg(t, st)
                l = self.newlabel()
                self.emit('adr x17, %s' % l)
                self.emit('str x17, [x28, #-8]!')
                self.emit('blr %s' % r)
                self.emit('mov x8, x0')
                self.out.append('%s:' % l)
            return
        cc = CC.get(mn[1:])
        if cc is None or not direct:
            self.err(st, 'unsupported jump')
        tgt = self.body_name(self.ren(t))
        if self.target(t, self.cur) is None:
            # Mach-O has no relocation for conditional branches to other files
            l = self.newlabel()
            self.emit('b.%s %s' % (INVERSE[cc], l))
            self.emit('b %s' % tgt)
            self.out.append('%s:' % l)
            return
        self.emit('b.%s %s' % (cc, tgt))

    def target_reg(self, t, st):
        o = self.operand(t, st)
        if isinstance(o, Reg) and o.bits == 64:
            return rn(o.i, 64)
        if isinstance(o, Mem):
            a = self.addr(o, 8)
            self.emit('ldr x16, %s' % a)
            return 'x16'
        self.err(st, 'bad jump target')

    # -- data movement
    def i_mov(self, st, ops, need, k):
        d, s = ops
        if isinstance(d, Xmm) or isinstance(s, Xmm):
            self.err(st, 'mov with xmm')
        bits = self.opsize(ops, st)
        if isinstance(d, Reg) and not d.high:
            if isinstance(s, Imm):
                if s.value is None:
                    self.err(st, 'label as immediate')
                if bits >= 32:
                    self.mov_imm(rn(d.i, bits), s.value, bits)
                    return
            elif isinstance(s, Reg) and bits >= 32:
                if s.i != d.i or bits == 32:
                    self.emit('mov %s, %s' % (rn(d.i, bits), rn(s.i, bits)))
                return
            elif isinstance(s, Mem) and bits >= 32:
                a = self.addr(s, bits // 8)
                self.emit('ldr %s, %s' % (rn(d.i, bits), a))
                return
        if isinstance(d, Mem):
            a = self.addr(d, bits // 8)
            if isinstance(s, Imm):
                v = s.value & ((1 << bits) - 1)
                r = self.imm_reg(v, 64 if bits == 64 else 32, 12)
                self.emit('%s %s, %s' % (self.ST[bits], r, a))
                return
            v = self.get(s, bits, 12)
            self.emit('%s %s, %s' % (self.ST[bits], v if bits == 64 else 'w' + v[1:] if v[0] == 'x' else v, a))
            return
        v = self.get(s, bits, 11)
        self.put(d, bits, v)

    def i_movabs(self, st, ops, need, k):
        return self.i_mov(st, ops, need, k)

    def i_lea(self, st, ops, need, k):
        d, m = ops
        if d.bits == 64:
            self.lea_into(rn(d.i, 64), m)
        else:
            self.lea_into('x11', m)
            self.emit('mov %s, w11' % rn(d.i, 32))

    def ext(self, st, ops, signed):
        d, s = ops
        sb = s.bits
        if sb is None:
            self.err(st, 'source size')
        db = d.bits
        dr = rn(d.i, 64 if db == 64 else 32)
        if db < 32:
            dr = 'w11'
        if isinstance(s, Mem):
            a = self.addr(s, sb // 8)
            if signed:
                op = {8: 'ldrsb', 16: 'ldrsh', 32: 'ldrsw'}[sb]
                self.emit('%s %s, %s' % (op, dr if sb < 32 or db == 64 else dr, a))
            else:
                self.emit('%s %s, %s' % ({8: 'ldrb', 16: 'ldrh', 32: 'ldr'}[sb], 'w' + dr[1:], a))
        else:
            if s.high:
                self.emit('%s %s, %s, #8, #8' % ('sbfx' if signed else 'ubfx', dr, rn(s.i, 64 if dr[0] == 'x' else 32)))
            elif signed:
                op = {8: 'sxtb', 16: 'sxth', 32: 'sxtw'}[sb]
                self.emit('%s %s, %s' % (op, dr, rn(s.i, 32)))
            else:
                if sb == 32:
                    self.emit('mov %s, %s' % ('w' + dr[1:], rn(s.i, 32)))
                else:
                    self.emit('%s %s, %s' % ({8: 'uxtb', 16: 'uxth'}[sb], 'w' + dr[1:], rn(s.i, 32)))
        if db < 32:
            self.put(d, db, 'w11')

    def i_movzx(self, st, ops, need, k):
        self.ext(st, ops, False)

    def i_movsx(self, st, ops, need, k):
        self.ext(st, ops, True)

    def i_movsxd(self, st, ops, need, k):
        if ops[1].bits is None:
            ops[1].bits = 32
        self.ext(st, ops, True)

    def i_xchg(self, st, ops, need, k):
        a, b = ops
        bits = self.opsize(ops, st)
        if isinstance(a, Reg) and isinstance(b, Reg) and bits >= 32 and not a.high and not b.high:
            ra, rb = rn(a.i, bits), rn(b.i, bits)
            self.emit('mov %s, %s' % (rn(11, bits), ra))
            self.emit('mov %s, %s' % (ra, rb))
            self.emit('mov %s, %s' % (rb, rn(11, bits)))
            return
        if isinstance(a, Mem):
            a, b = b, a
        if isinstance(b, Mem):
            ad = self.addr(b, bits // 8)
            v = self.load(b, bits, 13, ad)
            av = self.get(a, bits, 11)
            self.emit('%s %s, %s' % (self.ST[bits], av if bits == 64 else 'w' + av[1:], ad))
            self.put(a, bits, v)
            return
        va = self.get(a, bits, 11)
        vb = self.get(b, bits, 12)
        self.emit('mov x13, %s' % ('x' + va[1:]))
        self.put(a, bits, vb)
        self.put(b, bits, 'x13')

    def i_push(self, st, ops, need, k):
        s = ops[0]
        if isinstance(s, Reg):
            self.emit('str %s, [x28, #-8]!' % rn(s.i, 64))
        elif isinstance(s, Imm):
            r = self.imm_reg(s.value, 64, 11)
            self.emit('str %s, [x28, #-8]!' % r)
        else:
            a = self.addr(s, 8)
            self.emit('ldr x11, %s' % a)
            self.emit('str x11, [x28, #-8]!')

    def i_pop(self, st, ops, need, k):
        d = ops[0]
        if isinstance(d, Reg):
            self.emit('ldr %s, [x28], #8' % rn(d.i, 64))
        else:
            self.emit('ldr x11, [x28], #8')
            a = self.addr(d, 8)
            self.emit('str x11, %s' % a)

    def i_leave(self, st, ops, need, k):
        self.emit('mov x28, x20')
        self.emit('ldr x20, [x28], #8')

    def i_bswap(self, st, ops, need, k):
        d = ops[0]
        if d.bits < 32:
            self.err(st, 'narrow bswap')
        self.emit('rev %s, %s' % (rn(d.i, d.bits), rn(d.i, d.bits)))

    def i_cdq(self, st, ops, need, k):
        self.emit('asr w2, w8, #31')

    def i_cqo(self, st, ops, need, k):
        self.emit('asr x2, x8, #63')

    def i_cdqe(self, st, ops, need, k):
        self.emit('sxtw x8, w8')

    def i_cld(self, st, ops, need, k):
        self.df = False

    def i_std(self, st, ops, need, k):
        self.df = True

    def i_nop(self, st, ops, need, k):
        self.emit('nop')

    def i_ud2(self, st, ops, need, k):
        self.emit('brk #1')

    def i_syscall(self, st, ops, need, k):
        self.emit('bl x_syscall')

    # -- string instructions (rdi x0, rsi x1, rcx x3, al x8)
    def i_rep_movsb(self, st, ops, need, k):
        self.emit('bl x_rep_movsb_back' if self.df else 'bl x_rep_movsb')

    def i_rep_stosb(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards stos')
        self.emit('bl x_rep_stosb')

    def i_rep_stosd(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards stos')
        self.emit('bl x_rep_stosd')

    def i_rep_stosq(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards stos')
        self.emit('bl x_rep_stosq')

    def i_repe_cmpsb(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards cmps')
        self.emit('bl x_repe_cmpsb')

    i_repz_cmpsb = i_repe_cmpsb

    def i_repne_scasb(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards scas')
        self.emit('bl x_repne_scasb')

    i_repnz_scasb = i_repne_scasb

    def i_stosb(self, st, ops, need, k):
        self.emit('strb w8, [x0], #%d' % (-1 if self.df else 1))

    def i_lodsb(self, st, ops, need, k):
        self.emit('ldrb w11, [x1], #%d' % (-1 if self.df else 1))
        self.emit('bfi x8, x11, #0, #8')

    def i_movsb(self, st, ops, need, k):
        d = -1 if self.df else 1
        self.emit('ldrb w11, [x1], #%d' % d)
        self.emit('strb w11, [x0], #%d' % d)

    # -- arithmetic
    def alu(self, st, mn, ops, need):
        d, s = ops
        bits = self.opsize(ops, st)
        wb = mn not in ('cmp', 'test')
        da = None
        if isinstance(d, Mem):
            da = self.addr(d, bits // 8)
        if isinstance(d, Mem) and isinstance(s, Mem):
            self.err(st, 'two memory operands')
        if bits >= 32:
            return self.alu_wide(st, mn, d, s, bits, wb, da, need)
        return self.alu_narrow(st, mn, d, s, bits, wb, da, need)

    def invert_c(self):
        """Flip the modelled C flag (x86 CF inverted) without cfinv.

        cfinv is FEAT_FlagM (Armv8.4); the generated code must run on the
        baseline Armv8.0, so flip C through NZCV like clc/stc already do.
        x16 is the translator's flag scratch (see i_clc).
        """
        self.emit('mrs x16, nzcv')
        self.emit('eor x16, x16, #0x20000000')
        self.emit('msr nzcv, x16')

    def alu_wide(self, st, mn, d, s, bits, wb, da, need):
        fl = bool(need)
        A = self.get(d, bits, 11, a=da)
        R = rn(d.i, bits) if isinstance(d, Reg) else rn(11, bits)
        if not wb:
            R = rn(31, bits)
        B = None
        imm = None
        if isinstance(s, Imm):
            if s.value is None:
                self.err(st, 'label as immediate')
            imm = sext(s.value, bits) if bits == 64 else s.value & 0xffffffff
        else:
            B = self.get(s, bits, 12)
        if mn in ('add', 'sub', 'cmp'):
            op = 'sub' if mn in ('sub', 'cmp') else 'add'
            emitted = op
            suf = 's' if (fl or mn == 'cmp') else ''
            if imm is not None:
                v = imm if bits == 64 else sext(imm, 32)
                if arith_imm(v):
                    self.emit('%s%s %s, %s, #%d' % (op, suf, R, A, v))
                elif arith_imm(-v) and v != -(1 << (bits - 1)):
                    op2 = 'add' if op == 'sub' else 'sub'
                    self.emit('%s%s %s, %s, #%d' % (op2, suf, R, A, -v))
                    emitted = op2
                else:
                    B = self.imm_reg(imm, bits, 12)
                    self.emit('%s%s %s, %s, %s' % (op, suf, R, A, B))
            else:
                self.emit('%s%s %s, %s, %s' % (op, suf, R, A, B))
            if mn == 'add' and 'C' in need:
                # x86 add leaves CF = carry out; the model wants C = NOT CF.
                # If the emitted op is a real add and the liveness only needs
                # C, subs sets C = R >= X for a surviving addend X, which is
                # exactly NOT carry (baseline Armv8.0, same length as adds).
                # Anything else flips C through NZCV.
                cand = None
                if emitted == 'add' and wb and need == {'C'}:
                    if isinstance(s, (Reg, Mem)) and B is not None and B != R:
                        cand = B
                    elif A != R:
                        cand = A
                if cand is not None:
                    self.emit('subs %s, %s, %s' % (rn(31, bits), R, cand))
                else:
                    self.invert_c()
        elif mn in ('and', 'test'):
            suf = 's' if (fl or mn == 'test') else ''
            if imm is not None:
                if logical_imm(imm, bits):
                    self.emit('and%s %s, %s, #%d' % (suf, R, A, imm & ((1 << bits) - 1)))
                else:
                    B = self.imm_reg(imm, bits, 12)
                    self.emit('and%s %s, %s, %s' % (suf, R, A, B))
            else:
                self.emit('and%s %s, %s, %s' % (suf, R, A, B))
            if 'C' in need:
                self.invert_c()
        else:  # or, xor
            op = 'orr' if mn == 'or' else 'eor'
            if mn == 'xor' and isinstance(s, Reg) and isinstance(d, Reg) and s.i == d.i:
                self.emit('mov %s, #0' % R)
            elif imm is not None:
                if logical_imm(imm, bits):
                    self.emit('%s %s, %s, #%d' % (op, R, A, imm & ((1 << bits) - 1)))
                else:
                    B = self.imm_reg(imm, bits, 12)
                    self.emit('%s %s, %s, %s' % (op, R, A, B))
            else:
                self.emit('%s %s, %s, %s' % (op, R, A, B))
            if fl:
                self.emit('tst %s, %s' % (R, R))
                if 'C' in need:
                    self.invert_c()
        if wb and da is not None:
            self.emit('%s %s, %s' % (self.ST[bits], R, da))

    def alu_narrow(self, st, mn, d, s, bits, wb, da, need):
        sh = 32 - bits
        mask = (1 << bits) - 1
        simple = (not need) or (mn in ('cmp', 'sub') and need <= {'Z', 'C'}) or \
                 (mn in ('and', 'test', 'or', 'xor') and need <= {'Z', 'C', 'V'}) or \
                 (mn == 'add' and need <= {'Z'})
        op = {'add': 'add', 'sub': 'sub', 'cmp': 'sub', 'and': 'and', 'test': 'and', 'or': 'orr', 'xor': 'eor'}[mn]
        if simple:
            A = self.get(d, bits, 11, clean=bool(need), a=da)
            if isinstance(s, Imm):
                v = s.value & mask
                if op in ('add', 'sub') and arith_imm(v):
                    Bs = '#%d' % v
                elif op in ('and', 'orr', 'eor') and logical_imm(v, 32):
                    Bs = '#%d' % v
                else:
                    Bs = self.imm_reg(v, 32, 12)
            else:
                Bs = self.get(s, bits, 12, clean=bool(need))
            if not need:
                if not wb:
                    return
                self.emit('%s w11, %s, %s' % (op, A, Bs))
            elif op in ('sub',):
                self.emit('subs %s, %s, %s' % ('w11' if wb else 'wzr', A, Bs))
            elif op == 'and':
                self.emit('ands %s, %s, %s' % ('w11' if wb else 'wzr', A, Bs))
                if 'C' in need:
                    self.invert_c()
            elif op in ('orr', 'eor'):
                self.emit('%s w11, %s, %s' % (op, A, Bs))
                self.emit('tst w11, w11')
                if 'C' in need:
                    self.invert_c()
            else:  # add, Z only
                self.emit('add w11, %s, %s' % (A, Bs))
                self.emit('tst w11, #%d' % mask)
            if wb:
                self.put(d, bits, 'w11', a=da)
            return
        # exact flags: operate in the top bits
        A = self.get(d, bits, 11, a=da)
        self.emit('lsl w11, %s, #%d' % (A, sh))
        if isinstance(s, Imm):
            B = self.imm_reg((s.value & mask) << sh, 32, 12)
        else:
            B = self.get(s, bits, 12)
            self.emit('lsl w12, %s, #%d' % (B, sh))
            B = 'w12'
        R = 'w11' if wb else 'wzr'
        if op in ('add', 'sub', 'and'):
            self.emit('%ss %s, w11, %s' % (op, R, B))
        else:
            self.emit('%s w11, w11, %s' % (op, B))
            self.emit('tst w11, w11')
        if op in ('add', 'and', 'orr', 'eor') and 'C' in need:
            self.invert_c()
        if wb:
            self.emit('lsr w11, w11, #%d' % sh)
            self.put(d, bits, 'w11', a=da)

    def i_inc(self, st, ops, need, k):
        self.incdec(st, ops, need, k, 'add')

    def i_dec(self, st, ops, need, k):
        self.incdec(st, ops, need, k, 'sub')

    def incdec(self, st, ops, need, k, op):
        d = ops[0]
        bits = self.opsize(ops, st)
        if need and k in self.c_through:
            self.err(st, 'carry live across inc/dec')
        da = self.addr(d, bits // 8) if isinstance(d, Mem) else None
        if bits >= 32:
            A = self.get(d, bits, 11, a=da)
            R = rn(d.i, bits) if isinstance(d, Reg) else rn(11, bits)
            self.emit('%s%s %s, %s, #1' % (op, 's' if need else '', R, A))
            if da is not None:
                self.emit('%s %s, %s' % (self.ST[bits], R, da))
            return
        A = self.get(d, bits, 11, a=da)
        if not need:
            self.emit('%s w11, %s, #1' % (op, A))
        else:
            sh = 32 - bits
            self.emit('lsl w11, %s, #%d' % (A, sh))
            self.emit('mov w12, #%d' % (1 << sh))
            self.emit('%ss w11, w11, w12' % op)
            self.emit('lsr w11, w11, #%d' % sh)
        self.put(d, bits, 'w11', a=da)

    def i_neg(self, st, ops, need, k):
        d = ops[0]
        bits = self.opsize(ops, st)
        da = self.addr(d, bits // 8) if isinstance(d, Mem) else None
        if bits < 32:
            if need:
                self.err(st, 'narrow neg with flags')
            A = self.get(d, bits, 11, a=da)
            self.emit('neg w11, %s' % A)
            self.put(d, bits, 'w11', a=da)
            return
        A = self.get(d, bits, 11, a=da)
        R = rn(d.i, bits) if isinstance(d, Reg) else rn(11, bits)
        self.emit('neg%s %s, %s' % ('s' if need else '', R, A))
        if da is not None:
            self.emit('%s %s, %s' % (self.ST[bits], R, da))

    def i_not(self, st, ops, need, k):
        d = ops[0]
        bits = self.opsize(ops, st)
        da = self.addr(d, bits // 8) if isinstance(d, Mem) else None
        A = self.get(d, bits, 11, a=da)
        if bits >= 32 and isinstance(d, Reg):
            self.emit('mvn %s, %s' % (rn(d.i, bits), A))
            return
        R = rn(11, 64 if bits == 64 else 32)
        self.emit('mvn %s, %s' % (R, A))
        self.put(d, bits, R, a=da)

    def shift(self, st, mn, ops, need):
        d, c = ops
        bits = self.opsize([d], st)
        if need and ('C' in need or 'V' in need or bits < 32 or mn in ('rol', 'ror') or not isinstance(c, Imm)):
            self.err(st, 'shift flags')
        da = self.addr(d, bits // 8) if isinstance(d, Mem) else None
        op = {'shl': 'lsl', 'sal': 'lsl', 'shr': 'lsr', 'sar': 'asr', 'rol': 'ror', 'ror': 'ror'}[mn]
        if isinstance(c, Imm):
            n = c.value & (63 if bits == 64 else 31)
            if n == 0:
                return
        elif not (isinstance(c, Reg) and c.name == 'cl'):
            self.err(st, 'shift count')
        if bits >= 32:
            A = self.get(d, bits, 11, a=da)
            R = rn(d.i, bits) if isinstance(d, Reg) else rn(11, bits)
            if isinstance(c, Imm):
                if mn == 'rol':
                    n = (bits - n) % bits
                self.emit('%s %s, %s, #%d' % (op, R, A, n))
            else:
                cnt = rn(3, bits)
                if mn == 'rol':
                    self.emit('neg %s, %s' % (rn(12, bits), cnt))
                    cnt = rn(12, bits)
                self.emit('%s %s, %s, %s' % (op, R, A, cnt))
            if need:
                self.emit('tst %s, %s' % (R, R))
            if da is not None:
                self.emit('%s %s, %s' % (self.ST[bits], R, da))
            return
        # 8/16-bit
        A = self.get(d, bits, 11, a=da)
        if mn in ('rol', 'ror'):
            if bits == 16 and isinstance(c, Imm) and n == 8:
                self.emit('rev16 w11, %s' % A)
                self.put(d, bits, 'w11', a=da)
                return
            self.err(st, 'narrow rotate')
        if mn == 'shr':
            self.emit('%s w11, %s' % ('uxtb' if bits == 8 else 'uxth', A))
        elif mn == 'sar':
            self.emit('%s w11, %s' % ('sxtb' if bits == 8 else 'sxth', A))
        else:
            self.emit('mov w11, %s' % A)
        if isinstance(c, Imm):
            self.emit('%s w11, w11, #%d' % (op, n))
        else:
            self.emit('and w12, w3, #31')
            self.emit('%s w11, w11, w12' % op)
        self.put(d, bits, 'w11', a=da)

    def i_imul(self, st, ops, need, k):
        if need:
            self.err(st, 'imul flags')
        if len(ops) == 1:
            return self.widemul(st, ops[0], True)
        if ops[0].bits < 32:
            self.err(st, 'narrow imul')
        if len(ops) == 2:
            d, s = ops
            bits = d.bits
            B = self.get(s, bits, 12)
            self.emit('mul %s, %s, %s' % (rn(d.i, bits), rn(d.i, bits), B))
            return
        d, s, c = ops
        bits = d.bits
        A = self.get(s, bits, 11)
        B = self.imm_reg(c.value, bits, 12)
        self.emit('mul %s, %s, %s' % (rn(d.i, bits), A, B))

    def i_mul(self, st, ops, need, k):
        if need:
            self.err(st, 'mul flags')
        self.widemul(st, ops[0], False)

    def widemul(self, st, s, signed):
        bits = self.opsize([s], st)
        if bits == 64:
            B = self.get(s, 64, 12)
            if B in ('x8', 'x2'):
                self.emit('mov x12, %s' % B)
                B = 'x12'
            self.emit('%s x2, x8, %s' % ('smulh' if signed else 'umulh', B))
            self.emit('mul x8, x8, %s' % B)
        elif bits == 32:
            B = self.get(s, 32, 12)
            self.emit('%s x11, w8, %s' % ('smull' if signed else 'umull', B))
            self.emit('lsr x2, x11, #32')
            self.emit('mov w8, w11')
        else:
            self.err(st, 'narrow mul')

    def rdx_zero(self, k):
        """True when rdx/edx was cleared just before (same block)"""
        p = k - 1
        while p >= 0:
            st = self.stmts[p]
            if st.kind == 'label':
                return False
            if st.kind == 'ins':
                t = st.text.lower().replace(' ', '')
                if t in ('xoredx,edx', 'xorrdx,rdx', 'movedx,0', 'movrdx,0'):
                    return True
                if st.name in ('call', 'syscall', 'mul', 'imul', 'div', 'idiv', 'cqo', 'cdq', 'xchg') or \
                        re.search(r'\b(rdx|edx|dx|dl|dh)\b', st.args[0].lower() if st.args else ''):
                    return False
            p -= 1
        return False

    def cqo_before(self, k):
        p = k - 1
        while p >= 0:
            st = self.stmts[p]
            if st.kind == 'label':
                return False
            if st.kind == 'ins':
                if st.name == 'cqo':
                    return True
                if st.name in ('call', 'syscall', 'mul', 'imul', 'div', 'idiv', 'xchg') or \
                        re.search(r'\b(rdx|edx|dx|dl|dh|rax|eax|ax|al)\b', st.args[0].lower() if st.args else ''):
                    return False
            p -= 1
        return False

    def i_div(self, st, ops, need, k):
        self.divide(st, ops[0], False, k)

    def i_idiv(self, st, ops, need, k):
        self.divide(st, ops[0], True, k)

    def divide(self, st, s, signed, k):
        bits = self.opsize([s], st)
        if bits == 64:
            B = self.get(s, 64, 12)
            if B != 'x12':
                self.emit('mov x12, %s' % B)
            if signed:
                if not self.cqo_before(k):
                    self.err(st, 'idiv without cqo')
                self.emit('sdiv x11, x8, x12')
            elif self.rdx_zero(k):
                self.emit('udiv x11, x8, x12')
            else:
                self.emit('bl x_udiv128')
                return
            self.emit('msub x2, x11, x12, x8')
            self.emit('mov x8, x11')
            return
        if bits == 32:
            B = self.get(s, 32, 12)
            self.emit('sxtw x12, %s' % B if signed else 'mov w12, %s' % B)
            self.emit('mov w13, w8')
            self.emit('bfi x13, x2, #32, #32')
            self.emit('%s x11, x13, x12' % ('sdiv' if signed else 'udiv'))
            self.emit('msub x14, x11, x12, x13')
            self.emit('mov w8, w11')
            self.emit('mov w2, w14')
            return
        self.err(st, 'narrow div')

    def i_bt(self, st, ops, need, k):
        self.bittest(st, ops, need, None)

    def i_bts(self, st, ops, need, k):
        self.bittest(st, ops, need, 'orr')

    def i_btr(self, st, ops, need, k):
        self.bittest(st, ops, need, 'bic')

    def bittest(self, st, ops, need, op):
        d, b = ops
        bits = self.opsize([d], st)
        X = lambda r: 'x' + r[1:]
        if isinstance(d, Mem) and isinstance(b, Reg):
            # bit string: the index also selects the word
            self.lea_into('x13', d)
            if b.bits == 64:
                idx = rn(b.i, 64)
            else:
                self.emit('sxtw x14, %s' % rn(b.i, 32))
                idx = 'x14'
            sh = {64: 6, 32: 5, 16: 4}[bits]
            self.emit('asr x15, %s, #%d' % (idx, sh))
            self.emit('add x13, x13, x15, lsl #%d' % (sh - 3))
            self.emit('and x12, %s, #%d' % (idx, bits - 1))
            a = '[x13]'
        else:
            a = self.addr(d, bits // 8) if isinstance(d, Mem) else None
            if isinstance(b, Imm):
                self.emit('mov x12, #%d' % (b.value & (bits - 1)))
            else:
                self.emit('and x12, %s, #%d' % (rn(b.i, 64), bits - 1))
        V = X(self.get(d, bits, 11, a=a))
        if need:
            # C is the inverse of the bit; ZF stays, as on x86
            self.emit('lsr x15, %s, x12' % V)
            self.emit('and w15, w15, #1')
            self.emit('eor w15, w15, #1')
            self.emit('mrs x16, nzcv')
            self.emit('bfi x16, x15, #29, #1')
            self.emit('msr nzcv, x16')
        if op:
            self.emit('mov x14, #1')
            self.emit('lsl x14, x14, x12')
            if isinstance(d, Reg):
                self.emit('%s %s, %s, x14' % (op, rn(d.i, 64), V))
                if bits == 32:
                    self.emit('mov %s, %s' % (rn(d.i, 32), rn(d.i, 32)))
            else:
                self.emit('%s x11, %s, x14' % (op, V))
                self.store(11, bits, a)

    def i_bsr(self, st, ops, need, k):
        d, s = ops
        bits = d.bits
        if bits < 32:
            self.err(st, 'narrow bsr')
        S = self.get(s, bits, 12)
        self.emit('clz %s, %s' % (rn(11, bits), S))
        self.emit('mov %s, #%d' % (rn(13, bits), bits - 1))
        self.emit('sub %s, %s, %s' % (rn(11, bits), rn(13, bits), rn(11, bits)))
        self.emit('cmp %s, #0' % S)
        self.emit('csel %s, %s, %s, eq' % (rn(d.i, bits), rn(d.i, bits), rn(11, bits)))

    def i_bsf(self, st, ops, need, k):
        # the source 0 sets ZF and leaves the destination
        d, s = ops
        bits = d.bits
        if bits < 32:
            self.err(st, 'narrow bsf')
        S = self.get(s, bits, 12)
        self.emit('rbit %s, %s' % (rn(11, bits), S))
        self.emit('clz %s, %s' % (rn(11, bits), rn(11, bits)))
        self.emit('cmp %s, #0' % S)
        self.emit('csel %s, %s, %s, eq' % (rn(d.i, bits), rn(d.i, bits), rn(11, bits)))

    def i_clc(self, st, ops, need, k):
        # CF is the inverse of ARM's C; the other flags stay
        if need:
            self.emit('mrs x16, nzcv')
            self.emit('orr x16, x16, #0x20000000')
            self.emit('msr nzcv, x16')

    def i_stc(self, st, ops, need, k):
        if need:
            self.emit('mrs x16, nzcv')
            self.emit('and x16, x16, #0xffffffffdfffffff')
            self.emit('msr nzcv, x16')

    def i_rep_movsd(self, st, ops, need, k):
        if self.df:
            self.err(st, 'backwards movs')
        self.emit('lsl x3, x3, #2')
        self.emit('bl x_rep_movsb')

    # -- SSE2 integer: 128-bit registers as NEON vectors; v24 holds a memory operand, v25 is scratch
    def vsrc(self, o, st):
        if isinstance(o, Xmm):
            return o.i
        if isinstance(o, Mem):
            self.emit('ldr q24, %s' % self.addr(o, 16))
            return 24
        self.err(st, 'bad sse operand')

    def vop(self, st, ops, op, arr):
        d, s = ops
        if not isinstance(d, Xmm):
            self.err(st, 'bad sse operand')
        si = self.vsrc(s, st)
        self.emit('%s v%d.%s, v%d.%s, v%d.%s' % (op, d.i, arr, d.i, arr, si, arr))

    def i_por(self, st, ops, need, k):
        self.vop(st, ops, 'orr', '16b')

    def i_pand(self, st, ops, need, k):
        self.vop(st, ops, 'and', '16b')

    def i_pxor(self, st, ops, need, k):
        self.vop(st, ops, 'eor', '16b')

    def i_paddb(self, st, ops, need, k):
        self.vop(st, ops, 'add', '16b')

    def i_paddw(self, st, ops, need, k):
        self.vop(st, ops, 'add', '8h')

    def i_pmullw(self, st, ops, need, k):
        self.vop(st, ops, 'mul', '8h')

    def i_pcmpeqb(self, st, ops, need, k):
        self.vop(st, ops, 'cmeq', '16b')

    def i_punpcklbw(self, st, ops, need, k):
        self.vop(st, ops, 'zip1', '16b')

    def i_punpckldq(self, st, ops, need, k):
        self.vop(st, ops, 'zip1', '4s')

    def i_punpcklqdq(self, st, ops, need, k):
        self.vop(st, ops, 'zip1', '2d')

    def i_packuswb(self, st, ops, need, k):
        d, s = ops
        si = self.vsrc(s, st)
        self.emit('sqxtun v25.8b, v%d.8h' % d.i)
        self.emit('sqxtun2 v25.16b, v%d.8h' % si)
        self.emit('mov v%d.16b, v25.16b' % d.i)

    def vshift_imm(self, st, ops):
        d, c = ops
        if not isinstance(d, Xmm) or not isinstance(c, Imm):
            self.err(st, 'bad sse shift')
        return d, c.value

    def i_psrlw(self, st, ops, need, k):
        d, n = self.vshift_imm(st, ops)
        if n >= 16:
            self.emit('movi v%d.2d, #0' % d.i)
        elif n:
            self.emit('ushr v%d.8h, v%d.8h, #%d' % (d.i, d.i, n))

    def i_psrldq(self, st, ops, need, k):
        d, n = self.vshift_imm(st, ops)
        if n >= 16:
            self.emit('movi v%d.2d, #0' % d.i)
        elif n:
            self.emit('movi v25.2d, #0')
            self.emit('ext v%d.16b, v%d.16b, v25.16b, #%d' % (d.i, d.i, n))

    def i_pshufd(self, st, ops, need, k):
        d, s, c = ops
        si = self.vsrc(s, st)
        for i in range(4):
            self.emit('ins v25.s[%d], v%d.s[%d]' % (i, si, (c.value >> (2 * i)) & 3))
        self.emit('mov v%d.16b, v25.16b' % d.i)

    def i_pshuflw(self, st, ops, need, k):
        # the low four words shuffled, the high quadword copied
        d, s, c = ops
        si = self.vsrc(s, st)
        self.emit('mov v25.16b, v%d.16b' % si)
        for i in range(4):
            self.emit('ins v25.h[%d], v%d.h[%d]' % (i, si, (c.value >> (2 * i)) & 3))
        self.emit('mov v%d.16b, v25.16b' % d.i)

    def i_pmovmskb(self, st, ops, need, k):
        # the top bit of each byte: shifted down, then folded into the low byte of each half
        d, s = ops
        self.emit('ushr v25.16b, v%d.16b, #7' % s.i)
        self.emit('usra v25.8h, v25.8h, #7')
        self.emit('usra v25.4s, v25.4s, #14')
        self.emit('usra v25.2d, v25.2d, #28')
        self.emit('umov w11, v25.b[0]')
        self.emit('umov w12, v25.b[8]')
        self.emit('orr %s, w11, w12, lsl #8' % rn(d.i, 32))

    # -- SSE (scalar single precision)
    def fsrc(self, o, st, tmp=24, bits=32):
        if isinstance(o, Xmm):
            return o.i
        if isinstance(o, Mem):
            a = self.addr(o, bits // 8)
            self.emit('ldr %s%d, %s' % ('s' if bits == 32 else 'q', tmp, a))
            return tmp
        self.err(st, 'bad sse operand')

    def i_movss(self, st, ops, need, k):
        d, s = ops
        if isinstance(d, Mem):
            a = self.addr(d, 4)
            self.emit('str s%d, %s' % (s.i, a))
        elif isinstance(s, Mem):
            a = self.addr(s, 4)
            self.emit('ldr s%d, %s' % (d.i, a))
        else:
            self.emit('mov v%d.s[0], v%d.s[0]' % (d.i, s.i))

    def i_movd(self, st, ops, need, k):
        d, s = ops
        if isinstance(d, Xmm):
            if isinstance(s, Reg):
                self.emit('fmov s%d, %s' % (d.i, rn(s.i, 32)))
            else:
                a = self.addr(s, 4)
                self.emit('ldr s%d, %s' % (d.i, a))
        else:
            if isinstance(d, Reg):
                self.emit('fmov %s, s%d' % (rn(d.i, 32), s.i))
            else:
                a = self.addr(d, 4)
                self.emit('str s%d, %s' % (s.i, a))

    def fop(self, st, ops, op):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('%s s%d, s%d, s%d' % (op, d.i, d.i, si))

    def i_addss(self, st, ops, need, k):
        self.fop(st, ops, 'fadd')

    def i_subss(self, st, ops, need, k):
        self.fop(st, ops, 'fsub')

    def i_mulss(self, st, ops, need, k):
        self.fop(st, ops, 'fmul')

    def i_divss(self, st, ops, need, k):
        self.fop(st, ops, 'fdiv')

    def i_minss(self, st, ops, need, k):
        # x86: a < b ? a : b, the second operand on ties and NaN; flags stay
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcmgt s25, s%d, s%d' % (si, d.i))
        self.emit('bsl v25.8b, v%d.8b, v%d.8b' % (d.i, si))
        self.emit('ins v%d.s[0], v25.s[0]' % d.i)

    def i_maxss(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcmgt s25, s%d, s%d' % (d.i, si))
        self.emit('bsl v25.8b, v%d.8b, v%d.8b' % (d.i, si))
        self.emit('ins v%d.s[0], v25.s[0]' % d.i)

    def i_sqrtss(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fsqrt s%d, s%d' % (d.i, si))

    def i_cvtsi2ss(self, st, ops, need, k):
        d, s = ops
        bits = s.bits or 32
        S = self.get(s, bits, 11)
        self.emit('scvtf s%d, %s' % (d.i, S))

    def i_cvtss2si(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcvtns %s, s%d' % (rn(d.i, d.bits), si))

    def i_cvttss2si(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcvtzs %s, s%d' % (rn(d.i, d.bits), si))

    def i_roundss(self, st, ops, need, k):
        d, s, m = ops
        si = self.fsrc(s, st)
        mode = m.value & 7
        op = 'frinti' if mode & 4 else {0: 'frintn', 1: 'frintm', 2: 'frintp', 3: 'frintz'}[mode & 3]
        self.emit('%s s%d, s%d' % (op, d.i, si))

    def i_comiss(self, st, ops, need, k):
        # unordered: x86 sets ZF and CF, so Z=1 C=0 here
        d, s = ops
        si = self.fsrc(s, st)
        self.emit('fcmp s%d, s%d' % (d.i, si))
        self.emit('fccmp s%d, s%d, #4, vc' % (d.i, si))
        if 'N' in need:
            # SF is always clear on x86; ARM sets N for less than
            self.emit('mrs x16, nzcv')
            self.emit('and x16, x16, #0xffffffff7fffffff')
            self.emit('msr nzcv, x16')

    i_ucomiss = i_comiss

    def i_xorps(self, st, ops, need, k):
        d, s = ops
        if isinstance(s, Xmm) and s.i == d.i:
            self.emit('movi v%d.2d, #0' % d.i)
            return
        si = self.fsrc(s, st, bits=128)
        self.emit('eor v%d.16b, v%d.16b, v%d.16b' % (d.i, d.i, si))

    def i_andps(self, st, ops, need, k):
        d, s = ops
        si = self.fsrc(s, st, bits=128)
        self.emit('and v%d.16b, v%d.16b, v%d.16b' % (d.i, d.i, si))

    def i_movups(self, st, ops, need, k):
        d, s = ops
        if isinstance(d, Mem):
            a = self.addr(d, 16)
            self.emit('str q%d, %s' % (s.i, a))
        elif isinstance(s, Mem):
            a = self.addr(s, 16)
            self.emit('ldr q%d, %s' % (d.i, a))
        else:
            self.emit('mov v%d.16b, v%d.16b' % (d.i, s.i))

    i_movaps = i_movups
    i_movdqu = i_movups


# a translation takes well under a second and 30 MB; past these limits the analysis has run away
# and would otherwise take the machine's memory with it (the build runs one per core)
MAX_RSS = 512 << 20
MAX_SECONDS = 120


def guard(name):
    start = time.monotonic()
    # ru_maxrss is in bytes on macOS, in kilobytes on Linux
    unit = 1 if sys.platform == 'darwin' else 1024
    while True:
        time.sleep(0.02)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * unit
        secs = time.monotonic() - start
        if rss > MAX_RSS or secs > MAX_SECONDS:
            sys.stderr.write('arm64.py: %s: gave up after %.0f s at %d MB\n' % (name, secs, rss >> 20))
            os._exit(3)


def main(argv):
    inc = []
    defs = {}
    files = []
    aapcs = []
    callees = []
    i = 0
    os_name = 'darwin'
    while i < len(argv):
        a = argv[i]
        if a == '-I':
            inc.append(argv[i + 1])
            i += 2
            continue
        if a.startswith('-I'):
            inc.append(a[2:])
        elif a == '-D':
            k, _, v = argv[i + 1].partition('=')
            defs[k] = int(v, 0) if v else 1
            i += 2
            continue
        elif a.startswith('-D'):
            k, _, v = a[2:].partition('=')
            defs[k] = int(v, 0) if v else 1
        elif a == '--os':
            os_name = argv[i + 1]
            i += 2
            continue
        elif a.startswith('--os='):
            os_name = a[5:]
        elif a == '--aapcs-entry':
            aapcs.extend(x.strip() for x in argv[i + 1].split(',') if x.strip())
            i += 2
            continue
        elif a.startswith('--aapcs-entry='):
            aapcs.extend(x.strip() for x in a[14:].split(',') if x.strip())
        elif a == '--aapcs-callee':
            callees.extend(x.strip() for x in argv[i + 1].split(',') if x.strip())
            i += 2
            continue
        elif a.startswith('--aapcs-callee='):
            callees.extend(x.strip() for x in a[15:].split(',') if x.strip())
        elif a in ('-h', '--help'):
            sys.stdout.write('usage: arm64.py [--os {darwin,linux}] [--aapcs-entry SYM[,SYM...]]... '
                             '[--aapcs-callee SYM[,SYM...]]... [-I DIR] [-D SYM] in.s out.s\n')
            return 0
        else:
            files.append(a)
        i += 1
    if os_name == 'elf':
        os_name = 'linux'
    if os_name not in ('darwin', 'linux'):
        sys.stderr.write('arm64.py: --os must be darwin or linux (elf is an alias for linux)\n')
        return 2
    if len(files) != 2:
        sys.stderr.write('usage: arm64.py [--os {darwin,linux}] [--aapcs-entry SYM[,SYM...]]... '
                         '[--aapcs-callee SYM[,SYM...]]... [-I DIR] [-D SYM] in.s out.s\n')
        return 2
    threading.Thread(target=guard, args=(files[0],), daemon=True).start()
    try:
        src = Source(inc, defs)
        src.run(files[0])
        text = Translator(src, files[0], os_name, aapcs, callees).run()
    except Error as e:
        sys.stderr.write('arm64.py: %s\n' % e)
        return 1
    with open(files[1], 'w') as f:
        f.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
