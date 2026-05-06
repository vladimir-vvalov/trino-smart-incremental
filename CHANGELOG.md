# CHANGELOG

All notable changes to this project will be documented in this file.

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
