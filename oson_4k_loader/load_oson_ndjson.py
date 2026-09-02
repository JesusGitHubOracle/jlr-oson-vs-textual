#!/usr/bin/env python3
"""Load NDJSON documents into a BLOB column constrained as JSON FORMAT OSON."""

import argparse
import getpass
import json
import sys
from pathlib import Path

import oracledb


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ndjson_file", type=Path, help="Path to the NDJSON data file")
    parser.add_argument("--user", required=True, help="Database user name")
    parser.add_argument("--dsn", required=True, help="Easy Connect string or TNS alias")
    parser.add_argument(
        "--config-dir",
        help="Directory containing tnsnames.ora/sqlnet.ora (or an Autonomous DB wallet)",
    )
    parser.add_argument(
        "--oracle-client-lib-dir",
        help="Oracle Instant Client library directory; enables Thick mode",
    )
    parser.add_argument("--table", default="po_oson_over_4k", help="Target table name")
    parser.add_argument("--batch-size", type=int, default=100, help="Rows per commit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.ndjson_file.is_file():
        print(f"NDJSON file not found: {args.ndjson_file}", file=sys.stderr)
        return 2

    # This value is used as an identifier, not a bind variable. Restrict it to a
    # simple, unquoted Oracle table name to prevent unintended SQL construction.
    if not args.table.replace("_", "").isalnum() or not args.table:
        print("--table must contain only letters, digits, and underscores", file=sys.stderr)
        return 2

    password = getpass.getpass(f"Password for {args.user}: ")
    insert_sql = (
        f"INSERT INTO {args.table} (po_number, attributes) "
        "VALUES (:po_number, :attributes)"
    )

    if args.oracle_client_lib_dir:
        # Must happen before the first connection. Thick mode is required when
        # the database enforces Native Network Encryption (DPY-3001).
        oracledb.init_oracle_client(
            lib_dir=args.oracle_client_lib_dir,
            config_dir=args.config_dir,
        )

    loaded = 0
    pending_commit_count = 0
    with oracledb.connect(
        user=args.user,
        password=password,
        dsn=args.dsn,
        config_dir=args.config_dir,
    ) as connection:
        with connection.cursor() as cursor:
            # encode_oson() creates the binary OSON bytes client-side. Bind the
            # resulting bytes as a BLOB: this avoids the DB_TYPE_JSON bind
            # negotiation that some Oracle 19c patch levels reject, while the
            # target CHECK constraint validates the bytes are valid OSON.
            cursor.setinputsizes(po_number=oracledb.DB_TYPE_NUMBER,
                                  attributes=oracledb.DB_TYPE_BLOB)

            with args.ndjson_file.open(encoding="utf-8") as data_file:
                for line_number, line in enumerate(data_file, start=1):
                    if not line.strip():
                        continue
                    try:
                        document = json.loads(line)
                        po_number = document["PONumber"]
                    except (json.JSONDecodeError, KeyError) as error:
                        raise ValueError(
                            f"Invalid Purchase Order at line {line_number}: {error}"
                        ) from error

                    cursor.execute(insert_sql, {
                        "po_number": po_number,
                        "attributes": connection.encode_oson(document),
                    })
                    loaded += 1
                    pending_commit_count += 1

                    # Execute each OSON BLOB bind individually for broad 19c
                    # compatibility, committing periodically.
                    if pending_commit_count == args.batch_size:
                        connection.commit()
                        pending_commit_count = 0

            if pending_commit_count:
                connection.commit()

    print(f"Loaded {loaded} OSON documents into {args.table.upper()}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
