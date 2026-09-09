# CHANGELOG

All notable changes to this project will be documented in this file.

## 0.2.1 - (2026-09-09)

### Added

- `si_key_wrong_type` (string, default `'error'`): guard for `si_mode='in'` that blocks high-cardinality / imprecise `si_key` column types. Values: `'error'` / `'warn'` / `'ignore'`.

---

## 0.2.0 - (2026-09-08)

### Added

- `incremental_strategy = 'table'`: full-rebuild strategy matching the vanilla dbt-trino `table` (supports `on_table_exists` `rename` / `drop` / `replace` / `skip`). Under `--full-refresh`, `on_table_exists='skip'` is treated as `'rename'` so the table is still rebuilt.
- `si_check_update` (bool, default `false`): skips a run when the target is already newer than all its sources (via Iceberg `$snapshots.committed_at`). Ignored for `microbatch`; not evaluated on first run, `--full-refresh`, or views. On skip, `pre_hooks` are not run and the target is left untouched (`post_hooks` still run); the terminal shows `SUCCESS` (vs `CREATE TABLE (N rows)` for a real write), with a DEBUG-level (file-only) `SKIPPING ...` message.
- `si_check_ignore` (string / list): exclude upstreams from the freshness check by dbt-style label (source `'<source_name>.<table>'`, model `'<name>'`).
- `si_missing_committed` (string, default `'changed'`): behaviour when a source has no readable change timestamp — `'changed'` (do not skip) or `'unchanged'` (ignore that source).
- `si_table_format` (source/model meta, default `'iceberg'`): freshness source — `'iceberg'` (`$snapshots`), `'delta'` (`$history`), or `'none'` (skip this source's freshness, handled by `si_missing_committed`).
- File-only (DEBUG) diagnostic log listing the checked and ignored sources per run — a hint for tuning `si_check_ignore`.

### Fixed

- Scoped the `__dbt_tmp` drop to the delta branch (it only ever creates that temp relation), avoiding a redundant drop on the other branches.

---

## 0.1.3 - (2026-08-17)

### Added

- `si_get_metaconfig(key, default)` macro: version-safe config accessor (reads `config.meta` first, falls back to top-level `config.get`). Resolves `on_table_exists` and `views_enabled` regardless of placement, keeping the package compatible with dbt-core 1.10 / 1.11 / 1.12 as custom keys migrate into `config.meta` (`CustomKeyInConfigDeprecation`).

### Changed

- `on_table_exists` and `views_enabled` are now read via `si_get_metaconfig` instead of `config.get`.

---

## 0.1.2 - (2026-05-27)

### Removed

- `cleanup_snapshot_tmp()` macro: dropped from the package. Snapshot support for Trino has additional blocking issues beyond the `TABLE_ALREADY_EXISTS` workaround, making reliable snapshot usage impractical at this time.

---

## 0.1.1 - (2026-05-26)

### Added

- `cleanup_snapshot_tmp()` macro: drops the `__dbt_tmp` staging table before each snapshot run, preventing `TABLE_ALREADY_EXISTS` errors caused by leftover temp tables after Trino failures. Workaround for [starburstdata/dbt-trino#488](https://github.com/starburstdata/dbt-trino/issues/488), pending [starburstdata/dbt-trino#489](https://github.com/starburstdata/dbt-trino/pull/489).

---

## 0.1.0 - (2026-05-06)

### Added

- README with full documentation: configuration reference, strategy descriptions, and utility macro guide.
- Validation: compiler error when `si_mode` is set but `si_key` (and `unique_key`) is absent.

---

## 0.0.4 - (2026-05-06)

### Fixed

- Range modes for `delete+insert` — fixed generated invalid SQL alias.

---

## 0.0.3 - (2026-05-06)

### Fixed

- `si_min` / `si_max` — values are now correctly read via `config.get`
- Range mode — fixed undefined `_dbt_alias` variable used for MIN/MAX aliases

### Changed

- Code cleanup and deduplication; removed redundant intermediate variables
- `temporary_helpers.sql` renamed to `helpers.sql`
- New `build_where_clause(conditions)` macro extracted from duplicated logic

---

## 0.0.2 - (2026-05-05)

### Changed

- **`delete+insert` — refactored DELETE condition for composite `unique_key`**  
  Previously, composite keys were concatenated via `CAST(col1 AS VARCHAR) || '|' || CAST(col2 AS VARCHAR) IN (...)`, which prevented predicate pushdown in Trino/Iceberg and caused full table scans (worst case: 44s for 0 deleted rows).  
  Now each row is emitted as a typed per-column predicate: `(col1 = v1 and col2 = v2) or (col1 = v11 and col2 = v12) ...` — column types are preserved, enabling partition/file-level pruning.

- **Typed literals for `date` and `timestamp` columns in WHERE conditions**  
  Values read from `__dbt_tmp` for `date`-typed columns are now rendered as `DATE 'yyyy-mm-dd'` literals; `timestamp`-typed columns as `TIMESTAMP 'yyyy-mm-dd hh:mm:ss.nnn'`.  
  This ensures Trino can apply predicate pushdown without implicit casting.

---

## 0.0.1 - (2026-05-05)

### Added

- Custom incremental materialization for dbt-trino:
    - modified `delete+insert`
    - enhanced `merge`

- Utility macros:
  - `check_relation` — checks whether a relation exists
  - `forward` — inverted `ref()`: resolves a downstream (child) model instead of an upstream one
  - `get_values` — retrieves values from a relation
  - `is_incremental` — determines execution mode (incremental vs full-refresh)
