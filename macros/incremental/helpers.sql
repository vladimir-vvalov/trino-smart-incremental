{% macro get_incremental_tmp_relation_type(strategy, si_key, language) %}

  {%- set views_enabled = smart_incremental.si_get_metaconfig('views_enabled', true) -%}

  {% if language == 'sql' and (views_enabled and (strategy in ('default', 'append', 'merge') or (si_key is none))) %}
    {{ return('view') }}
  {% else %}  {#--  play it safe -- #}
    {{ return('table') }}
  {% endif %}
{% endmacro %}



{#--
  si_get_key_conditions

  Reads key values from tmp_relation and builds a WHERE clause
  for use in DELETE / MERGE statements.

  Parameters:
    tmp_relation        – Relation object (temp table/view with new data)
    unique_key          – dbt standard unique_key (informational, not used for filter)
    incremental_strategy – current strategy
    si_key              – list of key columns (already normalised to list)
    si_mode             – filter mode: none/'in', 'between', '>', '>=', '<', '<='
    si_min              – explicit min value (SQL literal); none → fetch from tmp_relation
    si_max              – explicit max value (SQL literal); none → fetch from tmp_relation
    si_null_key         – null handling in si_key values: 'warn', 'error', 'ignore'

  Returns: dict {
    'where_clause': str,  -- ready SQL condition (empty string → no filter built)
    'key_expr':     str,  -- SQL expression used for the key
  }
--#}
{% macro get_key_conditions(tmp_relation, unique_key, incremental_strategy, si_key, si_mode, si_min, si_max, si_null_key, dest_columns=none) %}

  {%- set _result = {'where_clause': '', 'key_expr': ''} -%}
  {%- set _null_policy = si_null_key if si_null_key else 'warn' -%}

  {#-- Only delete+insert uses a WHERE filter; all other strategies skip --#}
  {%- if incremental_strategy not in ('delete+insert',) -%}
    {{ return(_result) }}
  {%- endif -%}

  {#-- No si_key → nothing to filter on --#}
  {%- if not si_key or si_key | length == 0 -%}
    {{ return(_result) }}
  {%- endif -%}

  {#-- ── IN mode (default) ─────────────────────────────────────────────── --#}
  {%- set _eff_mode = si_mode if si_mode else 'in' -%}

  {%- if _eff_mode == 'in' -%}

    {#-- Guard BEFORE the distinct query runs: block high-cardinality/imprecise
         key types (timestamp/time/double/real/decimal) that would blow up the
         IN(...) list. Policy via si_key_wrong_type (default 'error'). --#}
    {%- do smart_incremental.check_si_key_types(si_key, dest_columns) -%}

    {%- if si_key | length > 1 -%}
      {#-- Composite key: (col1 = v1 and col2 = v2) or (col1 = v11 and col2 = v12) ...
           No CAST — each column stays typed, enabling predicate pushdown. --#}
      {%- set _rows = smart_incremental.clean_null_rows(
            smart_incremental.distinct_from_relation(tmp_relation, si_key | join(', '), col_types=dest_columns),
            _null_policy) -%}
      {%- set _row_conditions = [] -%}
      {%- for _row in _rows -%}
        {%- set _col_conds = [] -%}
        {%- for _col, _val in _row.items() -%}
          {%- do _col_conds.append(_col ~ ' = ' ~ _val) -%}
        {%- endfor -%}
        {%- do _row_conditions.append('(' ~ _col_conds | join(' and ') ~ ')') -%}
      {%- endfor -%}
      {%- if _row_conditions | length > 0 -%}
        {%- set _where = _row_conditions | join('\n        or ') -%}
        {%- do _result.update({'where_clause': _where, 'key_expr': si_key | join(', ')}) -%}
      {%- endif -%}

    {%- else -%}
      {#-- Single key: col IN (v1, v2, ...) --#}
      {%- set _rows = smart_incremental.clean_null_rows(
            smart_incremental.distinct_from_relation(tmp_relation, si_key[0], col_types=dest_columns),
            _null_policy) -%}
      {%- set _values = _rows | map(attribute=si_key[0]) | list -%}

      {%- if _values | length > 0 -%}
        {%- do _result.update({'where_clause': si_key[0] ~ ' IN (' ~ _values | join(', ') ~ ')', 'key_expr': si_key[0]}) -%}
      {%- endif -%}

    {%- endif -%}

  {#-- ── Range modes ───────────────────────────────────────────────────── --#}
  {%- elif _eff_mode in ('between', '>', '>=', '<', '<=') -%}

    {%- if si_key | length == 1 -%}
      {%- set _range_col = si_key[0] -%}
      {%- set _range_alias = si_key[0] -%}
      {%- set _key_expr = si_key[0] -%}
    {%- else -%}
      {%- set _cast_parts = [] -%}
      {%- for _k in si_key -%}
        {%- do _cast_parts.append('CAST(' ~ _k ~ ' AS VARCHAR)') -%}
      {%- endfor -%}
      {%- set _key_expr = _cast_parts | join(" || '|' || ") -%}
      {%- set _range_col = _key_expr ~ ' as __si_range_key__' -%}
      {%- set _range_alias = '__si_range_key__' -%}
    {%- endif -%}
    {%- set _agg = smart_incremental.minmax_from_relation(
          relation = tmp_relation,
          columns = [_range_col],
          agg_type = 'minmax'
    ) -%}
    {%- set _act_min = si_min if si_min is not none else _agg.get('min_' ~ _range_alias) -%}
    {%- set _act_max = si_max if si_max is not none else _agg.get('max_' ~ _range_alias) -%}

    {%- if _eff_mode == 'between' -%}
      {%- if _act_min is not none and _act_max is not none -%}
        {%- do _result.update({'where_clause': _key_expr ~ ' BETWEEN ' ~ _act_min ~ ' AND ' ~ _act_max, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- elif _eff_mode in ('>', '>=') -%}
      {%- if _act_min is not none -%}
        {%- do _result.update({'where_clause': _key_expr ~ ' ' ~ _eff_mode ~ ' ' ~ _act_min, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- elif _eff_mode in ('<', '<=') -%}
      {%- if _act_max is not none -%}
        {%- do _result.update({'where_clause': _key_expr ~ ' ' ~ _eff_mode ~ ' ' ~ _act_max, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- endif -%}

  {%- endif -%}

  {{ return(_result) }}
{% endmacro %}


{#--
  check_si_key_types

  Guard for si_mode='in': the IN-list is built from DISTINCT si_key values, so
  high-cardinality / imprecise column types blow up the IN(...) list (huge/slow
  DELETE) or hit si_in_rows_limit (silent duplicates). This macro blocks such
  types BEFORE the distinct query runs — no wasted work.

  Checked types (any si_key column matching → policy fires):
    timestamp (incl. 'timestamp with time zone'), time, double, real, decimal

  Composite si_key: fires if AT LEAST ONE column has a flagged type.

  Only meaningful for si_mode='in' — the caller must gate on that; range modes
  (between/>/>=/</<=) use MIN/MAX and are unaffected.

  Policy — si_key_wrong_type (via si_get_metaconfig):
    'error'  -> raise_compiler_error   [default]
    'warn'   -> exceptions.warn
    'ignore' -> no-op

  Params:
    si_key        – list of key column names (already normalised to list)
    dest_columns  – list of column objects (have .name and .data_type)
--#}
{% macro check_si_key_types(si_key, dest_columns) %}
  {%- set _policy = smart_incremental.si_get_metaconfig('si_key_wrong_type', 'error') -%}
  {%- if _policy == 'ignore' -%}
    {{ return(none) }}
  {%- endif -%}
  {%- if _policy not in ['error', 'warn', 'ignore'] -%}
    {%- do log("Invalid value for si_key_wrong_type (%s) specified. Setting default value (%s)." % (_policy, 'error')) -%}
    {%- set _policy = 'error' -%}
  {%- endif -%}

  {%- if not si_key or si_key | length == 0 -%}{{ return(none) }}{%- endif -%}
  {%- if not dest_columns or dest_columns | length == 0 -%}{{ return(none) }}{%- endif -%}

  {#-- substrings that flag a "dangerous for IN" type --#}
  {%- set _bad_types = ['timestamp', 'time', 'double', 'real', 'decimal'] -%}

  {#-- build lower-cased type lookup from dest_columns --#}
  {%- set _col_types = {} -%}
  {%- for _c in dest_columns -%}
    {%- do _col_types.update({_c.name: _c.data_type | lower}) -%}
  {%- endfor -%}

  {#-- collect offending "col (type)" entries --#}
  {%- set _offenders = [] -%}
  {%- for _k in si_key -%}
    {%- set _dtype = _col_types.get(_k, '') -%}
    {%- set _hit = [] -%}
    {%- for _bad in _bad_types -%}
      {%- if _bad in _dtype -%}{%- do _hit.append(1) -%}{%- endif -%}
    {%- endfor -%}
    {%- if _hit | length > 0 -%}
      {%- do _offenders.append(_k ~ ' (' ~ _dtype ~ ')') -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if _offenders | length > 0 -%}
    {%- set _msg -%}
(smart_incremental): si_mode='in' with high-cardinality/imprecise si_key column type(s): {{ _offenders | join(', ') }}.
The IN(...) delete list is built from DISTINCT values of these columns, which can produce a huge/slow DELETE or hit si_in_rows_limit (silent duplicates).
Use a range mode (si_mode='between' / '>=' / '<=' ...) for these columns, or reduce granularity (e.g. cast(ts as date)).
To override: set si_key_wrong_type='warn' or 'ignore'.
    {%- endset -%}
    {%- if _policy == 'error' -%}
      {%- do exceptions.raise_compiler_error(_msg) -%}
    {%- else -%}
      {%- do exceptions.warn(_msg) -%}
    {%- endif -%}
  {%- endif -%}
  {{ return(none) }}
{% endmacro %}


{#-- Filters null rows from a list of row dicts.
  A row is dropped if any of its column values is null/empty.
  Applies null_policy once if any null row was found.
  Returns cleaned list.
--#}
{% macro clean_null_rows(rows, null_policy) %}
  {%- set _clean = [] -%}
  {%- set _had_null = [] -%}
  {%- for _row in rows -%}
    {%- set _null_in_row = [] -%}
    {%- for _col, _val in _row.items() -%}
      {%- if _val is none or _val == '' -%}{%- do _null_in_row.append(1) -%}{%- endif -%}
    {%- endfor -%}
    {%- if _null_in_row | length > 0 -%}
      {%- do _had_null.append(1) -%}
    {%- else -%}
      {%- do _clean.append(_row) -%}
    {%- endif -%}
  {%- endfor -%}
  {%- if _had_null | length > 0 -%}
    {%- if null_policy == 'error' -%}
      {%- do exceptions.raise_compiler_error(
            "(smart_incremental) ERROR: NULL found in si_key values. "
            ~ "Set si_null_key='ignore' or 'warn' to suppress.") -%}
    {%- elif null_policy == 'warn' -%}
      {%- do exceptions.warn("(smart_incremental) WARNING: NULL found in si_key values, affected rows skipped.") -%}
    {%- endif -%}
  {%- endif -%}
  {{ return(_clean) }}
{% endmacro %}
