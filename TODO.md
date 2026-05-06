# TODO

## Not yet implemented

### `si_compare` — change-only UPDATE for merge

Config keys `si_compare`, `si_compare_columns`, `si_exclude_compare_columns` are read and
validated in the materialization but are never passed to or used by `trino__get_merge_sql`.

Required work:
- Pass `si_compare`, `si_compare_columns`, `si_exclude_compare_columns` in `strategy_arg_dict`
- In `trino__get_merge_sql`: build the update column subset (respecting `merge_update_columns` /
  `merge_exclude_columns`), apply whitelist / blacklist, generate `IS NOT DISTINCT FROM` condition
- Combine with `si_update_predicates` via `AND` when both are set
- In `incremental.sql`: before calling `get_incremental_sql`, when `si_compare = true`, run a
  pre-check query comparing `__dbt_tmp` against the target table on the compare column subset.
  If no differing rows are found -- skip the merge entirely (do not call `statement('main')`).
