"""
Run the SQL pipeline (Day 4): raw -> clean -> model, then reconcile.

1. Seeds clean.dq_expected from data/dq_injected.json, so every cleaning rule
   is checked against the number of problems the generator actually injected
   (no numbers are hard-coded in the SQL).
2. Runs sql/10_clean.sql, sql/20_model.sql, sql/30_reconcile.sql in order,
   splitting each file on GO lines. Each file runs in one transaction: if
   anything fails, that file's changes are rolled back.
3. Prints any result sets (the reconciliation tables) and exits with an error
   if any row has result = FAIL.

Run from the project root:
  python src\\load\\run_sql.py              (all files)
  python src\\load\\run_sql.py sql\\30_reconcile.sql   (just one)
"""

import json
import re
import sys
from pathlib import Path

import pyodbc

from load_raw import DATA, ROOT, connect, read_env

SQL_DIR = ROOT / "sql"

# Checks that should always find nothing; listed so they appear in the report.
ZERO_RULES = [
    "members_region_unmapped",
    "members_join_date_unparsed",
    "attendance_unknown_event_id",
    "sessions_unparsable_timestamp",
]


def seed_expected(cur: pyodbc.Cursor) -> None:
    injected = json.loads((DATA / "dq_injected.json").read_text())
    rows = [(k, int(v), "data/dq_injected.json")
            for k, v in injected.items() if k != "row_counts"]
    rows += [(k, 0, "should always be zero") for k in ZERO_RULES]
    cur.execute("IF SCHEMA_ID('clean') IS NULL EXEC('CREATE SCHEMA clean');")
    cur.execute("""
        DROP TABLE IF EXISTS clean.dq_expected;
        CREATE TABLE clean.dq_expected (
            rule_name       NVARCHAR(60)  NOT NULL PRIMARY KEY,
            expected_count  INT           NOT NULL,
            source          NVARCHAR(100) NOT NULL
        );
    """)
    cur.executemany(
        "INSERT INTO clean.dq_expected (rule_name, expected_count, source) VALUES (?, ?, ?)",
        rows)


def batches(sql_text: str) -> list[str]:
    parts = re.split(r"^\s*GO\s*;?\s*$", sql_text, flags=re.IGNORECASE | re.MULTILINE)
    return [p.strip() for p in parts if p.strip()]


def print_table(cur: pyodbc.Cursor) -> bool:
    """Print the current result set; return True if any row says FAIL."""
    cols = [d[0] for d in cur.description]
    rows = [["" if v is None else str(v) for v in r] for r in cur.fetchall()]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c)
              for i, c in enumerate(cols)]
    print()
    print("  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(v.ljust(w) for v, w in zip(r, widths)))
    if "result" not in cols:
        return False
    i = cols.index("result")
    return any(r[i] == "FAIL" for r in rows)


def run_file(conn: pyodbc.Connection, path: Path) -> bool:
    print(f"\n=== {path.relative_to(ROOT)}")
    cur = conn.cursor()
    failed = False
    for n, batch in enumerate(batches(path.read_text(encoding="utf-8")), 1):
        try:
            cur.execute(batch)
            while True:  # step through every result set so later errors surface
                if cur.description:
                    failed |= print_table(cur)
                if not cur.nextset():
                    break
        except pyodbc.Error as e:
            conn.rollback()
            sys.exit(f"\nError in {path.name}, batch {n} (rolled back):\n{e}")
    conn.commit()
    print("  done")
    return failed


def main() -> None:
    files = [Path(a).resolve() for a in sys.argv[1:]] or sorted(SQL_DIR.glob("[0-9]*.sql"))
    env = read_env(ROOT / ".env")
    print(f"Connecting to {env['SQL_SERVER']} / {env['SQL_DATABASE']}...")
    conn = connect(env)
    cur = conn.cursor()
    cur.execute("SET NOCOUNT ON;")
    seed_expected(cur)
    conn.commit()

    failed = False
    for f in files:
        failed |= run_file(conn, f)
    conn.close()

    if failed:
        sys.exit("\nSome checks FAILED - see the tables above.")
    print("\nAll checks passed.")


if __name__ == "__main__":
    main()
