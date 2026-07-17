#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers
import instr_cache

if not instr_cache.install(instr_cache.cache_path()):
    with atheris.instrument_imports():
        import sqlglot
import sqlglot

from sqlglot.errors import SqlglotError

list = ["bigquery", "hive", "impala", "mysql", "postgres", "presto", "clickhouse", "drill", "duckdb",
        "oracle", "redshift", "snowflake", "spark", "starrocks"]

def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        sqlglot.transpile(fdp.ConsumeRemainingString(), read=fdp.PickValueInList(list), write=fdp.PickValueInList(list))
    except (IndexError, SqlglotError, RecursionError):
        return -1
    except RuntimeError as e:
        if "Missing" in str(e):
            return -1
        raise
def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
