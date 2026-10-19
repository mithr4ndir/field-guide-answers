#!/usr/bin/env python3
"""Run drift.sql with the DuckDB Python package (pip install duckdb) and print every result.

Run from the 11-joins folder: python3 sql/run_sql.py
"""
import sys
from pathlib import Path

import duckdb

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("drift.sql")
body = "\n".join(line for line in path.read_text().splitlines() if not line.lstrip().startswith("--"))
for statement in body.split(";"):
    if statement.strip():
        result = duckdb.sql(statement)
        if result is not None:
            result.show()
