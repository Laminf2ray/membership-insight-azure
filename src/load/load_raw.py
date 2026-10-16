"""
Load the synthetic CSVs into the raw schema in Azure SQL (Day 3).

Raw means "exactly as received": every column is loaded as text, nothing is
cleaned, and each row is tagged with when and from which file it was loaded.
Cleaning happens later in SQL (raw -> clean -> model).

The script is safe to re-run: each raw table is dropped and recreated.
After loading, row counts in Azure SQL are checked against the counts the
generator recorded in data/dq_injected.json, and every load is logged in
raw.load_log.

Connection details come from the .env file in the project root:
  SQL_SERVER, SQL_DATABASE, SQL_USER, SQL_PASSWORD

Run from the project root:
  python src\\load\\load_raw.py
"""

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pyodbc

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
TABLES = ["members", "events", "attendance", "survey_responses", "web_sessions"]
BATCH = 5_000


def read_env(path: Path) -> dict:
    """Read KEY=VALUE lines from .env (no extra library needed)."""
    if not path.exists():
        sys.exit(f"Missing {path}. Copy .env.example to .env and fill it in.")
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    missing = [k for k in ("SQL_SERVER", "SQL_DATABASE", "SQL_USER", "SQL_PASSWORD")
               if not env.get(k)]
    if missing:
        sys.exit(f".env is missing values for: {', '.join(missing)}")
    return env


def pick_driver() -> str:
    for name in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server"):
        if name in pyodbc.drivers():
            return name
    sys.exit("No ODBC Driver 17/18 for SQL Server found. Install ODBC Driver 18 first.")


def connect(env: dict) -> pyodbc.Connection:
    conn_str = (
        f"Driver={{{pick_driver()}}};"
        f"Server=tcp:{env['SQL_SERVER']},1433;"
        f"Database={env['SQL_DATABASE']};"
        f"Uid={env['SQL_USER']};Pwd={env['SQL_PASSWORD']};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;"
    )
    # The free-tier database auto-pauses; the first attempt wakes it up.
    for attempt in range(1, 6):
        try:
            return pyodbc.connect(conn_str, autocommit=False)
        except pyodbc.Error as e:
            if attempt == 5:
                raise
            print(f"  Connection attempt {attempt} failed (database may be waking up). "
                  f"Retrying in 20s...\n  {str(e)[:160]}")
            time.sleep(20)


def ensure_log(cur: pyodbc.Cursor) -> None:
    cur.execute("""
        IF SCHEMA_ID('raw') IS NULL EXEC('CREATE SCHEMA raw');
        IF OBJECT_ID('raw.load_log') IS NULL
            CREATE TABLE raw.load_log (
                load_id      INT IDENTITY PRIMARY KEY,
                table_name   SYSNAME       NOT NULL,
                source_file  NVARCHAR(260) NOT NULL,
                rows_in_csv  INT           NOT NULL,
                rows_loaded  INT           NOT NULL,
                loaded_at    DATETIME2(0)  NOT NULL,
                seconds      DECIMAL(9,1)  NOT NULL
            );
    """)


def load_table(cur: pyodbc.Cursor, name: str, loaded_at: datetime) -> tuple[int, int, float]:
    path = DATA / f"{name}.csv"
    if not path.exists():
        sys.exit(f"Missing {path}. Run src\\generate\\generate_data.py first.")
    start = time.time()

    # Everything as text; only truly empty cells become NULL.
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[""])
    df = df.astype(object).where(df.notna(), None)

    cols = list(df.columns)
    col_defs = ",\n    ".join(f"[{c}] NVARCHAR(400) NULL" for c in cols)
    cur.execute(f"DROP TABLE IF EXISTS raw.[{name}];")
    cur.execute(f"""
        CREATE TABLE raw.[{name}] (
            {col_defs},
            [_source_file] NVARCHAR(260) NOT NULL,
            [_loaded_at]   DATETIME2(0)  NOT NULL
        );
    """)

    all_cols = ", ".join(f"[{c}]" for c in cols + ["_source_file", "_loaded_at"])
    marks = ", ".join("?" * (len(cols) + 2))
    sql = f"INSERT INTO raw.[{name}] ({all_cols}) VALUES ({marks})"

    cur.fast_executemany = True
    rows = df.values.tolist()
    for i in range(0, len(rows), BATCH):
        chunk = [r + [path.name, loaded_at] for r in rows[i:i + BATCH]]
        cur.executemany(sql, chunk)

    loaded = cur.execute(f"SELECT COUNT(*) FROM raw.[{name}]").fetchval()
    secs = round(time.time() - start, 1)
    cur.execute(
        "INSERT INTO raw.load_log (table_name, source_file, rows_in_csv, rows_loaded, loaded_at, seconds) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        name, path.name, len(df), loaded, loaded_at, secs,
    )
    return len(df), loaded, secs


def main() -> None:
    env = read_env(ROOT / ".env")
    expected = json.loads((DATA / "dq_injected.json").read_text())["row_counts"]

    print(f"Connecting to {env['SQL_SERVER']} / {env['SQL_DATABASE']}...")
    conn = connect(env)
    cur = conn.cursor()
    ensure_log(cur)
    conn.commit()

    loaded_at = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    problems = []
    print(f"\n{'table':<18}{'csv':>8}{'loaded':>9}{'expected':>10}{'secs':>7}")
    for name in TABLES:
        try:
            in_csv, loaded, secs = load_table(cur, name, loaded_at)
            conn.commit()  # one transaction per table
        except Exception:
            conn.rollback()
            raise
        ok = in_csv == loaded == expected[name]
        if not ok:
            problems.append(name)
        print(f"{name:<18}{in_csv:>8,}{loaded:>9,}{expected[name]:>10,}{secs:>7}  "
              f"{'OK' if ok else 'MISMATCH'}")

    conn.close()
    if problems:
        sys.exit(f"\nRow-count mismatch in: {', '.join(problems)}")
    print("\nAll raw tables loaded and reconciled. Details in raw.load_log.")


if __name__ == "__main__":
    main()
