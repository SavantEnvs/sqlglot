#!/usr/bin/env python3
"""Tiny transpile CLI used as the functional oracle (mayhem/test.sh drives it with known-answer
transpilations). Reads SQL on stdin, writes the transpiled statements (newline-joined) to stdout.

    echo "select 1" | sqlglot-cli [READ_DIALECT [WRITE_DIALECT]]
"""
import sys

import sqlglot


def main() -> int:
    read = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    write = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
    sql = sys.stdin.read()
    out = sqlglot.transpile(sql, read=read, write=write)
    sys.stdout.write("\n".join(out))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
