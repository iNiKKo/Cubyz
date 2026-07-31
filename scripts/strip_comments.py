#!/usr/bin/env python3
"""Safely strip comments from Zig source files and GLSL shader files.

Both languages share the same comment syntax (// line comments, /* */ block
comments) so one character-scanning state machine handles both. This is
deliberately NOT regex-based: naive regexes over "//" or "/*" break on string
literals that happen to contain those characters as text, e.g.
`std.mem.count(u8, vertex, "//")` in models.zig, or the literal string
"// this should all get skipped\nBut Not this" in zon.zig's test data - both
would be corrupted by a line-based or regex-based stripper.

Preserves:
  - String literals ("...") including escaped quotes (\") and escaped
    backslashes (\\) - a comment token inside a string is left completely
    alone.
  - Zig char literals ('x', '\n', etc.) - same escaping rules.
  - Zig multiline string literals (lines starting with \\, after leading
    whitespace) - passed through completely untouched, since these are raw
    string content where "//" has no special meaning and must never be
    scanned as a comment.
  - Doc comments (Zig's `///` and `//!`) are treated as ordinary comments and
    ARE stripped, same as `//` - if you want to keep doc comments, use
    --keep-doc-comments.
  - Blank line collapsing: consecutive blank lines left behind after comment
    removal are collapsed to at most one, and trailing whitespace on a line
    that only had a comment is trimmed away entirely (the line is dropped).

Usage:
    python3 scripts/strip_comments.py                  # dry run over the whole repo (src/ + shaders/)
    python3 scripts/strip_comments.py --write           # actually strip comments repo-wide, one file at a time
    python3 scripts/strip_comments.py --write --keep-doc-comments
    python3 scripts/strip_comments.py --check file1.zig file2.frag   # dry run on specific files only
    python3 scripts/strip_comments.py --write file1.zig file2.frag   # write specific files only

Run with no file arguments to walk the whole repo (src/**/*.zig and
assets/cubyz/shaders/**/*.{vert,frag,glsl,comp}) starting from the directory
this script is run in - intended to be run from the repo root. Pass explicit
file paths instead to limit it to just those files.
"""
import argparse
import sys
from pathlib import Path

SCAN_ROOTS = [
    ('src', ('.zig',)),
    ('assets/cubyz/shaders', ('.vert', '.frag', '.glsl', '.comp')),
]


def discover_files() -> list[Path]:
    found: list[Path] = []
    for root, extensions in SCAN_ROOTS:
        root_path = Path(root)
        if not root_path.is_dir():
            continue
        for ext in extensions:
            found.extend(sorted(root_path.rglob(f'*{ext}')))
    return found


def strip_comments(text: str, keep_doc_comments: bool) -> str:
    out = []
    i = 0
    n = len(text)
    line_start = True  # true when we're at the start of a line (only whitespace seen so far)

    while i < n:
        c = text[i]

        # --- Zig multiline string literal: a line whose first non-whitespace is \\ ---
        if line_start and c == '\\' and i + 1 < n and text[i + 1] == '\\':
            # Copy the rest of this line verbatim, including the newline.
            eol = text.find('\n', i)
            if eol == -1:
                out.append(text[i:])
                i = n
            else:
                out.append(text[i:eol + 1])
                i = eol + 1
            line_start = True
            continue

        if c == '\n':
            out.append(c)
            i += 1
            line_start = True
            continue

        if c in ' \t':
            out.append(c)
            i += 1
            continue

        line_start = False

        # --- String literal ---
        if c == '"':
            start = i
            i += 1
            while i < n and text[i] != '"':
                if text[i] == '\\' and i + 1 < n:
                    i += 2
                else:
                    i += 1
            i += 1  # consume closing quote (or hit EOF, harmless)
            out.append(text[start:i])
            continue

        # --- Char literal (Zig) --- guard against apostrophes used as e.g. lifetime-less
        # generics markers doesn't exist in Zig, so a leading ' is always a char literal here.
        if c == "'":
            start = i
            i += 1
            if i < n and text[i] == '\\' and i + 1 < n:
                i += 2
            elif i < n:
                i += 1
            if i < n and text[i] == "'":
                i += 1
            out.append(text[start:i])
            continue

        # --- Line comment ---
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            is_doc = (i + 2 < n and text[i + 2] == '/') or (i + 2 < n and text[i + 2] == '!')
            eol = text.find('\n', i)
            if keep_doc_comments and is_doc:
                segment = text[i:eol] if eol != -1 else text[i:]
                out.append(segment)
                i = eol if eol != -1 else n
                continue
            # Strip the comment; also eat one trailing space before it if the
            # rest of the line up to here was only whitespace we already emitted.
            i = eol if eol != -1 else n
            continue

        # --- Block comment ---
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            start = i
            i += 2
            depth = 1
            while i < n and depth > 0:
                if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
                    depth += 1
                    i += 2
                elif text[i] == '*' and i + 1 < n and text[i + 1] == '/':
                    depth -= 1
                    i += 2
                else:
                    i += 1
            # Zig doesn't actually have block comments, but GLSL does and nests
            # aren't standard C either - depth tracking is harmless overkill, kept
            # for safety. Replace the removed block comment with nothing.
            del start
            continue

        out.append(c)
        i += 1

    return ''.join(out)


def clean_blank_lines_and_trailing_ws(text: str) -> str:
    lines = text.split('\n')
    result = []
    blank_run = 0
    for line in lines:
        stripped = line.rstrip()
        if stripped == '':
            blank_run += 1
            if blank_run > 1:
                continue
            result.append('')
        else:
            blank_run = 0
            result.append(stripped)
    return '\n'.join(result)


def process_file(path: Path, keep_doc_comments: bool) -> tuple[str, str]:
    original = path.read_text(encoding='utf-8')
    stripped = strip_comments(original, keep_doc_comments)
    cleaned = clean_blank_lines_and_trailing_ws(stripped)
    return original, cleaned


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('files', nargs='*', help='Files to process; omit to scan the whole repo (src/ + shaders/)')
    parser.add_argument('--write', action='store_true', help='Actually write changes (default is dry-run)')
    parser.add_argument('--check', action='store_true', help='Dry run: report stats only, no changes (default)')
    parser.add_argument('--keep-doc-comments', action='store_true', help='Preserve /// and //! doc comments')
    parser.add_argument('--diff', action='store_true', help='Print a unified diff for each file in dry-run mode')
    args = parser.parse_args()

    if args.write and args.check:
        print('--write and --check are mutually exclusive', file=sys.stderr)
        sys.exit(1)

    if args.files:
        paths = [Path(f) for f in args.files]
    else:
        paths = discover_files()
        if not paths:
            print('No files found - run this from the repo root (expects src/ and/or '
                  'assets/cubyz/shaders/ to exist here).', file=sys.stderr)
            sys.exit(1)
        print(f'Scanning whole repo: {len(paths)} files found.\n')

    total_lines_before = 0
    total_lines_after = 0
    files_changed = 0

    for path in paths:
        if not path.is_file():
            print(f'skip (not a file): {path}', file=sys.stderr)
            continue
        if path.suffix not in ('.zig', '.glsl', '.vert', '.frag', '.comp'):
            print(f'skip (unsupported extension): {path}', file=sys.stderr)
            continue

        original, cleaned = process_file(path, args.keep_doc_comments)
        before_lines = original.count('\n') + 1
        after_lines = cleaned.count('\n') + 1
        total_lines_before += before_lines
        total_lines_after += after_lines

        changed = original != cleaned
        if changed:
            files_changed += 1
        print(f'{path}: {before_lines} -> {after_lines} lines' + ('' if changed else ' (no change)'))

        if args.diff and changed:
            import difflib
            diff = difflib.unified_diff(
                original.splitlines(keepends=True),
                cleaned.splitlines(keepends=True),
                fromfile=str(path),
                tofile=str(path) + ' (stripped)',
            )
            sys.stdout.writelines(diff)

        if args.write and changed:
            path.write_text(cleaned, encoding='utf-8')

    print(f'\nTotal: {total_lines_before} -> {total_lines_after} lines '
          f'({total_lines_before - total_lines_after} removed) across {len(paths)} files, '
          f'{files_changed} modified')
    if not args.write:
        print('(dry run - pass --write to actually modify files)')


if __name__ == '__main__':
    main()
