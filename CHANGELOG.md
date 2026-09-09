# CHANGELOG

All notable changes to this project will be documented in this file.

## 0.2.0 - (2026-09-08)

### Added

- **`incremental_strategy = 'table'`**: full-rebuild strategy that behaves like the vanilla dbt-trino `table` materialization. No temp relation and no delta — the whole table is rewritten via the shared `on_table_exists_logic` helper. Supports `on_table_exists` values `rename` / `drop` / `replace` / `skip` (the `skip` mode is enabled only for this strategy, matching vanilla `table`). Added so that `si_check_update` can be applied uniformly without touching the vanilla materialization.
- **`si_check_update` (bool, default `false`)**: skips an incremental run when the target model is already newer than every one of its source tables. Freshness is read from Apache Iceberg `<table>$snapshots.committed_at`. The check runs only on a genuine incremental run of an existing table (not the first run, not `--full-refresh`, not a view) and is ignored for the `microbatch` strategy. It is evaluated **before** `pre_hooks`, and when it decides to skip: `pre_hooks` are skipped and a no-op `main` (`select 1 where false`) is issued so the target table — data and Iceberg snapshots alike — is left completely untouched (a `pre_hook` mutating `{{ this }}` would otherwise bump the target's `committed_at` and make the check skip forever).
- **`--full-refresh` + `on_table_exists='skip'`**: under a full refresh, `on_table_exists='skip'` is overridden to `'rename'` so the table is actually rebuilt (plain `CREATE TABLE IF NOT EXISTS` would leave an existing table untouched). This gap exists in vanilla dbt-trino; fixed in `smart_incremental` only.
- **`si_check_ignore` (string / list, default none)**: a flat list of dbt-style labels to EXCLUDE from the freshness comparison. Source form is `'<source_name>.<table>'` (mirrors `source('hermes','dbo__activities')`); model/seed/snapshot form is the plain `'<name>'`. A dot always denotes a source (dbt forbids dots in resource names, so there is no collision). Ignored nodes are dropped entirely — their own upstreams are NOT descended into. Useful when a noisy but insignificant upstream (e.g. a frequently-rebuilt intermediate) would otherwise defeat the skip. Entries that match nothing raise a warning (typo guard).
- **`si_missing_committed` (string, default `'changed'`)**: controls behaviour when a source has no resolvable change timestamp (missing metadata table or `max` is NULL). `'changed'` treats the source as just-changed (do not skip); `'unchanged'` ignores it in the comparison. Named without the word *snapshot* to avoid confusion with the dbt `snapshot` resource.
- **`si_table_format` (source/model meta, default `'iceberg'`)**: per-source declared metadata format used to read freshness — `'iceberg'` → `<id>$snapshots`.max(`committed_at`), `'delta'` → `<id>$history`.max(`timestamp`). Any other value marks the source unreadable (handled per `si_missing_committed`).
- `resolve_source_tables(node, ignore)` macro: resolves the full set of physical source tables feeding a model, looking transitively through `ephemeral` and `view` nodes down to tables/sources/seeds/snapshots. Each result carries a dbt-style `label` used for `si_check_ignore` matching and for logging.
- `si_should_skip_update()` / `si_freshness_select()` / `si_snapshots_relation()` macros: single-query, Trino-side comparison of the latest change timestamp between the target and its sources.
- **File-only diagnostic log**: before the freshness query, `smart_incremental` writes (at DEBUG level, i.e. to `logs/dbt.log` only, never the terminal) a copy-paste-ready list of the sources being `checking:` and the `ignored:` labels — an author hint for tuning `si_check_ignore`. Costs no extra queries (walks the already-resolved list in memory).

### Changed

- **Skip logging moved off the terminal**: the `SKIPPING update ...` message is now DEBUG (file-only). In the terminal the run status alone conveys the outcome — `SUCCESS` means the update was skipped by `si_check_update`, `CREATE TABLE (N rows)` means a real write.

### Fixed

- **Redundant temp-relation drop**: `drop_relation_if_exists(tmp_relation)` was executed unconditionally for every branch, but only the delta path ever creates `__dbt_tmp`. The drop is now scoped to the delta branch, removing a wasted metastore round-trip on the `table` / full-refresh / first-run / view / skip paths.

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
