# CHANGELOG

All notable changes to this project will be documented in this file.

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
