#!/usr/bin/env python3
"""Count Elisp delimiters in FILE or a standalone START..END line range.

  python3 tools/paren-audit.py FILE
  python3 tools/paren-audit.py -v FILE 336 372

Ranges are independent fragments: select complete forms, not the middle of a
string or form. Ignores strings, line comments, escaped symbol characters and
character literals. Counts parentheses and vector brackets, not braces.
This is a balance aid, not a reader/compiler or a check of syntactic meaning.
"""
import argparse
from pathlib import Path


def audit(path, lo=1, hi=None, verbose=False):
    lines = Path(path).read_text(encoding="utf-8").splitlines(keepends=True)
    hi = len(lines) if hi is None else hi
    if not lines and lo == 1 and hi == 0:
        print("OK: empty file")
        return 0
    if not 1 <= lo <= hi <= len(lines):
        raise ValueError(f"range must satisfy 1 <= START <= END <= {len(lines)}")
    stack = []
    string_start = None
    counts = {c: 0 for c in "()[]"}
    problems = 0
    # Skip counts may span a newline (escaped string/symbol continuation).
    escaped = False
    for lineno in range(lo, hi + 1):
        line = lines[lineno - 1]
        col = 0
        while col < len(line):
            ch = line[col]
            if escaped:
                escaped = False
            elif string_start:
                if ch == "\\":
                    escaped = True
                elif ch == '"':
                    string_start = None
            elif ch == ";":
                break
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                string_start = (lineno, col + 1)
            elif ch == "?" and (col == 0 or line[col - 1].isspace()
                                or line[col - 1] in "([\"'`,"):
                # Elisp ?x, ?\\(, ?\\C-\\M-x, ?\\N{UNICODE NAME}.
                col += 1
                while col < len(line) and line[col] == "\\":
                    col += 1
                    if col + 1 < len(line) and line[col] in "CMSAHs" and line[col + 1] == "-":
                        col += 2
                    elif col < len(line) and line[col] == "^":
                        col += 1
                    else:
                        break
                if line[col:col + 2] == "N{":
                    end = line.find("}", col + 2)
                    col = len(line) if end < 0 else end
            elif ch in "([":
                counts[ch] += 1
                stack.append((lineno, col + 1, ch))
            elif ch in ")]":
                counts[ch] += 1
                if not stack:
                    print(f"{lineno}:{col + 1}: STRAY CLOSER {ch!r}")
                    problems += 1
                else:
                    ln, c, opener = stack.pop()
                    if (opener, ch) not in (("(", ")"), ("[", "]")):
                        print(f"{lineno}:{col + 1}: MISMATCH {ch!r}; {opener!r} opened at {ln}:{c}")
                        problems += 1
            col += 1
        if verbose:
            print(f"{lineno:4d} depth={len(stack):3d} {line.rstrip()}")
    if string_start:
        print(f"UNTERMINATED STRING at {string_start[0]}:{string_start[1]}")
        problems += 1
    for ln, col, opener in stack:
        print(f"UNCLOSED {opener!r} at {ln}:{col}")
        problems += 1
    print(f"lines {lo}-{hi}: (={counts['(']} )={counts[')']} [={counts['[']} ]={counts[']']}")
    if not problems:
        print("OK: balanced")
    return int(bool(problems))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("file")
    parser.add_argument("start", nargs="?", type=int, default=1)
    parser.add_argument("end", nargs="?", type=int)
    args = parser.parse_args()
    try:
        raise SystemExit(audit(args.file, args.start, args.end, args.verbose))
    except (OSError, ValueError) as error:
        parser.error(str(error))
