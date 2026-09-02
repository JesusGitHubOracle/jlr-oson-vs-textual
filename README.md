# Oracle OSON vs. Text JSON Benchmark

This repository compares Oracle Binary JSON (OSON) with UTF-8 textual JSON stored in `BLOB` columns. The included dataset contains 10,000 purchase-order documents, each larger than 4 KB.

The workflow is:

1. Create the OSON source table, `PO_OSON_OVER_4K`.
2. Load `purchase_orders_over_4k.ndjson` with the included Python loader.
3. Run the SQL benchmark, which generates an equivalent text-JSON table and reports the results.

## Prerequisites

- An Oracle Database environment that supports `JSON FORMAT OSON` (the scripts were prepared for Oracle Database 19c).
- Python 3.8 or later.
- The Python `oracledb` driver:

  ```bash
  python3 -m pip install oracledb
  ```

- A database user with permission to create tables, indexes, and views in its schema.

For databases that require Oracle Native Network Encryption, install a matching Oracle Instant Client and use the loader's `--oracle-client-lib-dir` option below.

## 1. Create the OSON table

Connect as the benchmark user in SQL*Plus, SQLcl, SQL Developer, or a comparable Oracle SQL client and run:

```sql
CREATE TABLE po_oson_over_4k (
  po_number  NUMBER NOT NULL,
  attributes BLOB NOT NULL,
  CONSTRAINT po_oson_over_4k_pk PRIMARY KEY (po_number),
  CONSTRAINT po_oson_over_4k_json_chk
    CHECK (attributes IS JSON FORMAT OSON (SIZE LIMIT 32M))
);
```

The table must be empty before the initial load. The dataset uses `PONumber` values as unique primary keys.

## 2. Load the dataset as OSON

From the repository root, run the loader. It prompts for the password, so do not put a password on the command line or commit one to the repository.

```bash
python3 oson_4k_loader/load_oson_ndjson.py \
  oson_4k_loader/purchase_orders_over_4k.ndjson \
  --user YOUR_DATABASE_USER \
  --dsn 'db-host.example.com:1521/service_name'
```

The loader converts every NDJSON document to OSON on the client and inserts it into `PO_OSON_OVER_4K`. It commits every 100 rows by default. A successful run ends with:

```text
Loaded 10000 OSON documents into PO_OSON_OVER_4K.
```

Use a TNS alias instead of an Easy Connect string when appropriate:

```bash
python3 oson_4k_loader/load_oson_ndjson.py \
  oson_4k_loader/purchase_orders_over_4k.ndjson \
  --user YOUR_DATABASE_USER \
  --dsn MY_TNS_ALIAS \
  --config-dir /path/to/wallet_or_network_admin
```

If the connection reports `DPY-3001`, enable python-oracledb Thick mode with Oracle Instant Client:

```bash
python3 oson_4k_loader/load_oson_ndjson.py \
  oson_4k_loader/purchase_orders_over_4k.ndjson \
  --user YOUR_DATABASE_USER \
  --dsn MY_TNS_ALIAS \
  --config-dir /path/to/wallet_or_network_admin \
  --oracle-client-lib-dir /path/to/instantclient
```

Verify the load in your SQL client:

```sql
SELECT COUNT(*) AS documents FROM po_oson_over_4k;
```

To load the same dataset again, first clear the existing rows (or recreate the table), then rerun the loader:

```sql
DELETE FROM po_oson_over_4k;
COMMIT;
```

## 3. Run the benchmark

Run the SQL script while connected as the owner of `PO_OSON_OVER_4K`:

```bash
sqlplus YOUR_DATABASE_USER@MY_TNS_ALIAS @oson_4k_loader/benchmark_oson_vs_text.sql
```

Or open [`oson_4k_loader/benchmark_oson_vs_text.sql`](oson_4k_loader/benchmark_oson_vs_text.sql) in your SQL client and execute it as a script.

The benchmark:

- Builds `PO_JSON_TEXT_OVER_4K` by serializing the same OSON documents to textual JSON.
- Creates matching `JSON_VALUE` indexes and gathers optimizer statistics.
- Measures multi-field `JSON_VALUE` projection, `JSON_TABLE` line-item expansion, and a full-document `JSON_TRANSFORM` update.
- Prints elapsed milliseconds per execution and the OSON benefit relative to text JSON.

The update test rolls its data changes back before the next test; the benchmark's setup tables and indexes remain afterward for inspection. Each rerun replaces `PO_JSON_TEXT_OVER_4K` and `PO_JSON_BENCHMARK_RESULTS`, recreates the OSON predicate indexes, and replaces the relational view `PO_OSON_OVER_4K_RELATIONAL_V`.

## Optional cleanup

After reviewing the results, remove the derived objects if they are no longer needed:

```sql
DROP TABLE po_json_text_over_4k PURGE;
DROP TABLE po_json_benchmark_results PURGE;
DROP VIEW po_oson_over_4k_relational_v;
DROP INDEX po_oson_over_4k_costcenter_ix;
DROP INDEX po_oson_over_4k_user_ix;
```

This cleanup intentionally leaves `PO_OSON_OVER_4K` and its loaded dataset in place.
