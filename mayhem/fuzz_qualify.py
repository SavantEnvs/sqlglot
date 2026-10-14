#!/usr/bin/env python3

import atheris
import sys
import instr_cache

DIALECTS = instr_cache.DIALECTS

if not instr_cache.install(instr_cache.cache_path()):
    with atheris.instrument_imports():
        instr_cache.import_targets()
import sqlglot
from sqlglot import exp, optimizer
from sqlglot.errors import SqlglotError

SCHEMA = {
    "my_db": {
        "other": {
            "some_view": {"v": "VARIANT"},
            "my_table": {"items": "ARRAY<STRUCT<name STRING, age INT>>", "id": "INT"},
            "events": {"id": "INT", "payload": "VARIANT", "tags": "ARRAY<STRING>"},
        }
    }
}


def TestOneInput(data):
    if not data:
        return -1
    dialect = DIALECTS[data[0] % len(DIALECTS)]
    sql = data[1:].decode("utf-8", errors="ignore")
    try:
        expression = sqlglot.parse_one(sql, read=dialect)
    except (IndexError, SqlglotError, RecursionError):
        return -1
    if not isinstance(expression, exp.Query):
        return -1
    try:
        optimizer.qualify.qualify(expression, schema=SCHEMA, dialect=dialect, db="other", catalog="my_db")
    except SqlglotError:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
