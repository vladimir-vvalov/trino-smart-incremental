# trino-smart-incremental

Custom incremental materialization for dbt-trino with enhanced filtering, typed DELETE conditions, and extended merge predicates.

[![dbt](https://img.shields.io/badge/dbt-%3E%3D1.9.0-orange.svg)](https://docs.getdbt.com)
[![Trino](https://img.shields.io/badge/Trino-compatible-blue.svg)](https://trino.io/)
[![Iceberg](https://img.shields.io/badge/Apache%20Iceberg-compatible-blue.svg)](https://iceberg.apache.org/)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Standard dbt Parameters](#standard-dbt-parameters)
  - [si_* Parameters](#si_-parameters)
- [Strategies](#strategies)
  - [append](#append)
  - [delete+insert](#deleteinsert)
  - [merge](#merge)
- [Utilities](#utilities)
- [Requirements](#requirements)
- [Changelog](#changelog)
- [License](#license)

---

## Overview

`smart_incremental` is a dbt package that provides a custom `smart_incremental` materialization for Trino.
It extends the standard `incremental` strategies with:

- **Typed scalar DELETE conditions** -- no subqueries in `WHERE`, enabling predicate pushdown in Trino/Iceberg
- **Flexible target filtering** for `delete+insert` -- by value list, range, or comparison operator
- **Extended merge predicates** -- additional `WHEN MATCHED` conditions without touching the JOIN
- **Non-conflicting design** -- does not override any default dbt macro; all standard parameters work as-is
- **Drop-in compatibility** -- switching between `smart_incremental` and `incremental` requires no config changes

The package is designed for data engineers working with large Iceberg tables in Trino who need precise,
efficient incremental updates without relying on subquery-based filtering.

---

## Features

### Typed Scalar DELETE Conditions

The standard `delete+insert` strategy in dbt-trino deletes rows using a subquery:

```sql
DELETE FROM target WHERE unique_key IN (SELECT unique_key FROM __dbt_tmp)
```

This prevents predicate pushdown in Trino/Iceberg and results in full table scans.

`smart_incremental` reads the key values at compile time and injects them as typed scalar literals:

```sql
-- Single key column
DELETE FROM target
WHERE date_col IN (DATE '2024-01-01', DATE '2024-01-02', DATE '2024-01-03')

-- Composite key
DELETE FROM target
WHERE (store_id = 10 AND date_col = DATE '2024-01-01')
   OR (store_id = 11 AND date_col = DATE '2024-01-02')
```

Each column preserves its original type (`DATE`, `TIMESTAMP`, `VARCHAR`, `INTEGER`, etc.),
allowing Trino to apply file-level and partition-level pruning.

### Flexible Target Filtering

Instead of limiting DELETE to exact-value matching, you can define a range or comparison operator:

- `si_mode = 'in'` -- delete rows matching DISTINCT key values from the temp relation (default)
- `si_mode = 'between'` -- delete rows in `[si_min, si_max]`
- `si_mode = '>'` / `'>='` -- delete rows above a lower bound
- `si_mode = '<'` / `'<='` -- delete rows below an upper bound

Boundaries (`si_min`, `si_max`) can be provided explicitly or read automatically from the temp relation.

### Extended Merge Predicates

`si_update_predicates` adds extra conditions to the `WHEN MATCHED` clause without modifying the JOIN
condition -- useful for skipping updates under specific business rules:

```sql
WHEN MATCHED AND (status != 'locked') THEN UPDATE SET ...
```

### Safe NULL Handling

When `si_mode = 'in'` is used with a key column that may contain NULLs, `si_null_key` controls behavior:
`warn` (default), `error`, or `ignore`.

### Custom `is_incremental()` Check

The standard dbt `is_incremental()` hardcodes `materialized == 'incremental'` and does not recognize
custom materializations. This package overrides `is_incremental()` within its own namespace to correctly
detect `smart_incremental` runs:

```sql
-- Use this in your model SQL:
{% if smart_incremental.is_incremental() %}
```

---

## Installation

Add to your `packages.yml`:

```yaml
packages:
  - git: "https://github.com/vladimir-vvalov/trino-smart-incremental.git"
    revision: v0.1.0
```

Then run:

```bash
dbt deps
```

---

## Quick Start

```sql
{{ config(
    materialized = 'smart_incremental',
    incremental_strategy = 'delete+insert',
    unique_key = 'id',
    si_key = 'created_date',
    si_mode = 'in'
) }}

select
    id,
    value,
    created_date
from {{ ref('source_table') }}
{% if smart_incremental.is_incremental() %}
where created_date >= current_date - interval '3' day
{% endif %}
```

On each incremental run, `smart_incremental` reads DISTINCT values of `created_date` from the temp
relation and generates a typed `DELETE ... WHERE created_date IN (DATE '...', ...)` before inserting.

---

## Configuration

### Standard dbt Parameters

All standard `incremental` parameters are supported with identical semantics.

| Parameter | Type | Description |
|-----------|------|-------------|
| `unique_key` | string / list | Join key for `merge`; also used as fallback `si_key` for `delete+insert` when `si_key` is not set |
| `incremental_predicates` | list | Additional `WHERE` conditions applied to the temp relation during incremental runs |
| `merge_update_columns` | list | Explicit list of columns to update in `WHEN MATCHED` |
| `merge_exclude_columns` | list | Columns to exclude from `WHEN MATCHED` updates |
| `on_schema_change` | string | Schema drift behavior: `ignore`, `fail`, `append_new_columns`, `sync_all_columns` |
| `on_table_exists` | string | Full-refresh table replacement mode: `rename` (default), `drop`, `replace` |
| `views_enabled` | boolean | Whether the adapter may use a view as the temp relation. Default `true`. Set to `false` if your connector does not support views (e.g. some Iceberg catalogs). When `false`, a temp table is always used instead. |

### si_* Parameters

All new parameters use the `si_` prefix to avoid conflicts with standard dbt parameters and to visually
associate them with this package. Standard parameters are not affected when switching materializations.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `si_key` | string / list | `none` | Column(s) used to filter the target table before insert. This is the primary filter key for `delete+insert`. You may use `unique_key` instead -- both are treated identically for this purpose. Semantically, `si_key` is more accurate: in `delete+insert` the key column is a slice or partition key, not necessarily a row-identity key the way `unique_key` implies. |
| `si_mode` | string | `none` | Filtering mode for `delete+insert`: `'in'`, `'between'`, `'>'`, `'>='`, `'<'`, `'<='`. Required when using `delete+insert` strategy. In `'in'` mode, rows where any `si_key` column is NULL are excluded from the value set (NULL cannot match `IN (...)` in SQL). |
| `si_min` | string / number | `none` | Lower bound for range modes (`between`, `>`, `>=`). If not set, read as `MIN(si_key)` from the temp relation. |
| `si_max` | string / number | `none` | Upper bound for range modes (`between`, `<`, `<=`). If not set, read as `MAX(si_key)` from the temp relation. |
| `si_update_predicates` | string / list | `none` | Additional condition(s) for `WHEN MATCHED` in `merge`. Joined with `AND`. Ignored silently when using standard `incremental`. |
| `si_null_key` | string | `'warn'` | Behavior when NULL values are found among `si_key` values in `si_mode = 'in'`: `'warn'` -- log a warning and continue (NULLs will not be deleted from target), `'error'` -- raise a compiler error, `'ignore'` -- silently skip. |
| `si_in_rows_limit` | integer | `1000000` | Row cap applied when reading values from a relation into memory (used by utility macros). Also controls the WARNING threshold for large `IN(...)` lists. Set via model config or `vars` in `dbt_project.yml`. |

---

## Strategies

### append

Unchanged from the dbt standard: `INSERT INTO target SELECT * FROM tmp`.
All `si_*` parameters are ignored.

### delete+insert

The enhanced `delete+insert` runs a typed DELETE before the standard INSERT.

**Required parameters:** `si_key` (or `unique_key`) and `si_mode`.

**How it works:**

1. The model SQL is materialized into a temp relation (`__dbt_tmp`).
2. Key values (or bounds) are read from `__dbt_tmp` at compile time.
3. A DELETE statement is executed against the target table using scalar literals -- no subqueries.
4. A standard INSERT populates the target from `__dbt_tmp`.

**Value mode** (`si_mode = 'in'`):

```sql
-- Single key column
DELETE FROM target
WHERE date_col IN (DATE '2024-01-01', DATE '2024-01-02')

-- Composite key: each combination becomes a typed row predicate
DELETE FROM target
WHERE (store_id = 10 AND date_col = DATE '2024-01-01')
   OR (store_id = 11 AND date_col = DATE '2024-01-02')
```

For composite `si_key`, each column retains its original type -- no casting or string concatenation.
This enables Trino to use partition pruning and file skipping.

**Range modes** (`si_mode = 'between'`, `'>'`, `'>='`, `'<'`, `'<='`):

```sql
-- between
DELETE FROM target WHERE date_col BETWEEN DATE '2024-01-01' AND DATE '2024-01-31'

-- greater-than or equal
DELETE FROM target WHERE date_col >= DATE '2024-01-01'
```

When `si_min` / `si_max` are not set explicitly, the materialization queries `MIN` / `MAX` of `si_key`
from the temp relation automatically. Set them explicitly (e.g. via `var()`) to skip that extra query.

**NULL handling in value mode:**

Rows with a NULL in any `si_key` column are excluded from the value set (NULL cannot match `IN (...)`).
The `si_null_key` parameter controls what happens when such rows are found: `'warn'` (default) -- log a
warning and continue, `'error'` -- raise a compiler error, `'ignore'` -- skip silently.

**`incremental_predicates` interaction:**

When set, predicates are appended to the DELETE statement with `AND`:

```sql
DELETE FROM target
WHERE date_col IN (DATE '2024-01-01')
  AND (partition_col = 'A')
```

### merge

The `merge` strategy works like the standard dbt-trino merge, with one extension: `si_update_predicates`.

**`si_update_predicates`** adds extra conditions to the `WHEN MATCHED` block:

```sql
MERGE INTO target AS DBT_INTERNAL_DEST
USING __dbt_tmp AS DBT_INTERNAL_SOURCE
ON (DBT_INTERNAL_SOURCE.id = DBT_INTERNAL_DEST.id)

WHEN MATCHED AND (status != 'locked') THEN UPDATE SET
    value = DBT_INTERNAL_SOURCE.value,
    ...

WHEN NOT MATCHED THEN INSERT (id, value, ...) VALUES (...)
```

Multiple predicates (passed as a list) are joined with `AND`.

`incremental_predicates` continues to work on the JOIN condition, same as in the standard implementation.

---

## Utilities

The package exposes several utility macros callable from model SQL.

### `smart_incremental.is_incremental()`

Returns `true` when the model should run incrementally (relation exists, no `--full-refresh`, and
`materialized = 'smart_incremental'`).

Use this instead of the built-in `is_incremental()`, which does not recognize custom materializations.

```sql
{% if smart_incremental.is_incremental() %}
where updated_at > (select max(updated_at) from {{ this }})
{% endif %}
```

An optional `use_cache` parameter controls the lookup strategy: `none` (default -- cache then DB),
`true` (cache only), `false` (DB only).

### `smart_incremental.check_relation(relation)` / `check_table(table, schema, database)`

Checks whether a relation exists in the database.

- `check_relation(relation)` -- accepts a Relation object (e.g. `this`, `ref(...)`)
- `check_table(table, schema, database)` -- accepts plain name strings

The lookup uses adapter cache first, falling back to an `information_schema` query on cache miss.
For non-target databases, a `system.metadata.catalogs` check is performed first.

```sql
{% if smart_incremental.check_relation(ref('my_model')) %}
    ...
{% endif %}
```

### `smart_incremental.forward(model_name)`

Inverse of `ref()`: resolves a **downstream** (child) model by name. Useful when an intermediate model
needs a watermark from a downstream mart table to filter only new or changed rows.

The macro traverses the graph upward (BFS) from the target model to verify it is reachable as a
downstream node of the current model. Raises a compiler error if the model is not downstream, or
if it is an ephemeral or view materialization.

**When `{{ this }}` is not enough**

A common pattern for incremental models is:

```sql
where updated_at > (select max(updated_at) from {{ this }})
```

This works well for a single monolithic model. Once the domain grows and the pipeline is split into
several intermediate models feeding one mart, the watermark must come from the **mart** -- because
each intermediate model tracks only its own slice and `{{ this }}` gives a per-model maximum, not
the overall state of the output table.

`forward` combined with `max_from_relation` lets an intermediate model read the watermark directly
from the mart that is downstream of it:

```sql
-- models/intermediate/int_orders.sql
-- Pipeline: int_orders (this) --> mart_orders (downstream, persisted table)

{% set last_upd = smart_incremental.max_from_relation(
    smart_incremental.forward('mart_orders'),
    columns = ['updated_at']
) %}

select
    id,
    status,
    updated_at
from {{ ref('raw_orders') }}
{% if smart_incremental.is_incremental() and last_upd %}
where updated_at > {{ last_upd.get('max_updated_at') }}
{% endif %}
```

`max_from_relation` returns `{}` when the relation does not yet exist, so on the first run the
`WHERE` clause is skipped and the model loads in full. On subsequent runs it filters against the
mart's current watermark, regardless of how many intermediate models feed that mart.

`is_same_tag` (default `true`) limits BFS to nodes sharing at least one tag with the target model,
reducing graph traversal cost.

### `smart_incremental.values_from_query(relation, sql_query, row_name_by, is_quoting)`

Executes a query and returns results as a nested dict `{ row_id: { col_name: value } }`.

```jinja
{% set rows = smart_incremental.values_from_query(
    relation = ref('lookup'),
    sql_query = "select code, label from " ~ ref('lookup'),
    row_name_by = 'code'
) %}
```

Related macros in the same family:

| Macro | Description |
|-------|-------------|
| `values_from_relation(relation)` | Read all rows via `SELECT *` |
| `values_from_table(table, schema, database)` | Read by plain table name strings |
| `distinct_from_relation(relation, expression)` | Read DISTINCT values of an expression |
| `minmax_from_relation(relation, columns)` | Read MIN / MAX per column |
| `max_from_relation(relation, columns)` | Read MAX per column |
| `min_from_relation(relation, columns)` | Read MIN per column |
| `build_where_clause(conditions)` | Build a `WHERE ... AND ...` string from a condition list |

All read macros apply a row limit from `si_in_rows_limit` (default `1 000 000`) and return `{}`
when the relation does not exist.

`is_quoting` controls value formatting: `true` -- single-quote all values, `false` -- raw,
`none` (default) -- auto: `DATE`/`TIMESTAMP` typed literals, booleans unquoted, numbers unquoted,
everything else single-quoted.

### Tip: local macro wrappers

Package macros are called with a package prefix (e.g. `smart_incremental.forward('name')`).
If you use a macro frequently across many models, you can define a thin local wrapper in your
project's `macros/` folder to keep model SQL concise:

```sql
-- macros/forward.sql
{% macro forward(model_name, is_same_tag=true) %}
    {{ return(smart_incremental.forward(model_name, is_same_tag)) }}
{% endmacro %}
```

After that, your models can call `forward('child_model')` without the package prefix.
The same pattern applies to `is_incremental()`, `check_relation()`, and the `values_from_*` family.

---

## Requirements

- dbt >= 1.9.0, < 2.0.0
- dbt-trino adapter
- Apache Iceberg tables (recommended; the typed-literal DELETE optimization is most impactful on Iceberg)

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## License

[Apache 2.0](LICENSE)
