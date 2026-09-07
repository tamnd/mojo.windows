"""Find `except` blocks that read a value the `try` passed to a raising call.

A value whose last use is an argument of a call that raises is destroyed on the
way out of that call.  Naming it inside the handler does not count as a use, so
the handler reads a slot that something else has already taken.  On Linux the
freed bytes are usually still there and it works by luck.  On Windows the
allocator scrubs them and the value comes out as a run of 0xDF.  #207 is the
issue, #201 was the first one found and #206 is the shape of the fix, which is
a use after the handler.

Run it over a tree of Mojo sources:

    python3 scripts/find-dead-handler-values.py .upstream/modular/Mojo

The output is candidates and not findings.  It matches on shape and cannot see
types, so it reports borrowed parameters, trivial types with no destructor and
fields that the handler reassigns, none of which are the bug.  Every hit needs
reading.  What it is good for is bounding the problem: if it prints twenty
lines then the answer is to fix them, and if it prints two thousand then the
answer is a compiler change.
"""

import os
import re
import sys

IDENT = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")
CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")

KEYWORDS = {
    "if", "else", "elif", "for", "while", "try", "except", "finally", "with",
    "def", "fn", "struct", "trait", "alias", "var", "let", "return", "raise",
    "and", "or", "not", "in", "is", "None", "True", "False", "self", "print",
    "String", "Int", "Bool", "Float64", "UInt", "pass", "continue", "break",
    "as", "from", "import", "comptime", "ref", "out", "read", "mut", "owned",
}


def strip_literals(src):
    """Blank out comments and string bodies, keeping line structure intact.

    Identifiers inside docstrings and messages are not uses of anything, and
    they were most of the noise on the first pass.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == "#":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c in "\"'":
            q = src[i:i + 3]
            trip = q in ('"""', "'''")
            delim = q if trip else c
            out.append(" " * len(delim))
            i += len(delim)
            while i < n:
                if src[i] == "\\":
                    out.append("  ")
                    i += 2
                    continue
                if src.startswith(delim, i):
                    out.append(" " * len(delim))
                    i += len(delim)
                    break
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def indent_of(line):
    return len(line) - len(line.lstrip())


def block(lines, start, base):
    """Lines strictly indented deeper than base, starting at start."""
    out = []
    i = start
    while i < len(lines):
        s = lines[i]
        if s.strip() and indent_of(s) <= base:
            break
        out.append((i, s))
        i += 1
    return out, i


def args_of_calls(text):
    """Identifiers that appear inside the parentheses of some call."""
    names = set()
    for m in CALL.finditer(text):
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        inner = text[m.end():i]
        for n in IDENT.findall(inner):
            if n not in KEYWORDS:
                names.add(n)
    return names


def enclosing_def_end(lines, idx, try_indent):
    """End of the function body containing the try at idx."""
    d = None
    for i in range(idx, -1, -1):
        s = lines[i]
        if s.strip() and indent_of(s) < try_indent:
            if re.match(r"\s*(def|fn)\s", s):
                d = i
                break
            if re.match(r"\s*(struct|trait)\s", s):
                return None
    if d is None:
        return None
    base = indent_of(lines[d])
    j = d + 1
    while j < len(lines):
        s = lines[j]
        if s.strip() and indent_of(s) <= base:
            break
        j += 1
    return j


def scan(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = strip_literals(raw).split("\n")
    hits = []
    for i, line in enumerate(lines):
        if not re.match(r"\s*try\s*:\s*$", line):
            continue
        ti = indent_of(line)
        body, j = block(lines, i + 1, ti)
        # The except clauses that belong to this try.
        handlers = []
        while j < len(lines) and re.match(r"\s*except\b", lines[j]) \
                and indent_of(lines[j]) == ti:
            hb, j = block(lines, j + 1, ti)
            handlers.append(hb)
        if not handlers:
            continue
        passed = args_of_calls("\n".join(s for _, s in body))
        if not passed:
            continue
        end = enclosing_def_end(lines, i, ti)
        after = "\n".join(lines[j:end]) if end else ""
        after_names = {n for n in IDENT.findall(after) if n not in KEYWORDS}
        for hb in handlers:
            htext = "\n".join(s for _, s in hb)
            used = {n for n in IDENT.findall(htext) if n not in KEYWORDS}
            risky = (passed & used) - after_names
            # A name only assigned inside the handler is not the bug.
            risky = {
                n
                for n in risky
                if not re.search(r"^\s*(var\s+)?" + n + r"\s*=", htext, re.M)
            }
            if risky:
                hits.append((i + 1, sorted(risky)))
    return hits


def main(roots):
    total = 0
    files = 0
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for name in sorted(names):
                if not name.endswith(".mojo"):
                    continue
                p = os.path.join(dirpath, name)
                hits = scan(p)
                if hits:
                    files += 1
                    rel = os.path.relpath(p, roots[0])
                    for ln, names_ in hits:
                        print(f"{rel}:{ln}: {', '.join(names_)}")
                        total += 1
    print(f"\n{total} candidate sites in {files} files")


main(sys.argv[1:])
