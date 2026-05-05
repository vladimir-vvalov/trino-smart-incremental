{% macro get_incremental_tmp_relation_type(strategy, si_key, language) %}

  {%- set views_enabled = config.get('views_enabled', true) -%}

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
{% macro get_key_conditions(tmp_relation, unique_key, incremental_strategy, si_key, si_mode, si_min, si_max, si_null_key) %}

  {%- set _dbt_alias = '__si_dbt_key__' -%}
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

  {#-- Build key expression (raw SQL, no alias — alias is in _select_expr only) --#}
  {%- if si_key | length == 1 -%}
    {%- set _key_expr = si_key[0] -%}
  {%- else -%}
    {%- set _cast_parts = [] -%}
    {%- for _k in si_key -%}
      {%- do _cast_parts.append('CAST(' ~ _k ~ ' AS VARCHAR)') -%}
    {%- endfor -%}
    {%- set _key_expr = _cast_parts | join(" || '|' || ") -%}
  {%- endif -%}
  {%- set _select_expr = _key_expr ~ ' AS ' ~ _dbt_alias -%}

  {#-- ── IN mode (default) ─────────────────────────────────────────────── --#}
  {%- set _eff_mode = si_mode if si_mode else 'in' -%}

  {%- if _eff_mode == 'in' -%}

    {%- set _vdict = smart_incremental.distinct_from_relation(tmp_relation, _select_expr) -%}
    {%- set _values = _vdict.get(_dbt_alias, []) -%}

    {#-- NULL handling --#}
    {%- set _has_nulls = (none in _values) or ('' in _values) -%}
    {%- if _has_nulls -%}
      {%- if _null_policy == 'error' -%}
        {%- do exceptions.raise_compiler_error(
              "smart_incremental: NULL found in si_key values. "
              ~ "Set si_null_key='ignore' or 'warn' to suppress.") -%}
      {%- elif _null_policy == 'warn' -%}
        {%- do log("smart_incremental WARNING: NULL found in si_key values. "
                   ~ "Nulls are excluded from the IN filter.", info=true) -%}
      {%- endif -%}
      {%- set _values = _values | reject('none') | reject('equalto', '') | list -%}
    {%- endif -%}

    {%- if _values | length > 0 -%}
      {%- set _where = _key_expr ~ ' IN (' ~ _values | join(', ') ~ ')' -%}
      {%- do _result.update({'where_clause': _where, 'key_expr': _key_expr}) -%}
    {%- endif -%}

  {#-- ── Range modes ───────────────────────────────────────────────────── --#}
  {%- elif _eff_mode in ('between', '>', '>=', '<', '<=') -%}

    {#-- Aliases for MIN/MAX columns in the aggregate query — always _dbt_alias-based. --#}
    {%- set _min_alias = 'min_' ~ _dbt_alias -%}
    {%- set _max_alias = 'max_' ~ _dbt_alias -%}

    {%- set _agg_sql %}
select min({{ _key_expr }}) as {{ _min_alias }}, max({{ _key_expr }}) as {{ _max_alias }}
from {{ tmp_relation }}
    {%- endset -%}
    {%- set _agg_raw = smart_incremental.values_from_query(relation = tmp_relation, sql_query = _agg_sql, row_name_by = '__index__') -%}
    {%- set _agg = _agg_raw.get(0, {}) -%}
    {%- set _act_min = si_min if si_min is not none else _agg.get(_min_alias) -%}
    {%- set _act_max = si_max if si_max is not none else _agg.get(_max_alias) -%}

    {%- if _eff_mode == 'between' -%}
      {%- if _act_min is not none and _act_max is not none -%}
        {%- set _where = _key_expr ~ ' BETWEEN ' ~ _act_min ~ ' AND ' ~ _act_max -%}
        {%- do _result.update({'where_clause': _where, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- elif _eff_mode in ('>', '>=') -%}
      {%- if _act_min is not none -%}
        {%- set _where = _key_expr ~ ' ' ~ _eff_mode ~ ' ' ~ _act_min -%}
        {%- do _result.update({'where_clause': _where, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- elif _eff_mode in ('<', '<=') -%}
      {%- if _act_max is not none -%}
        {%- set _where = _key_expr ~ ' ' ~ _eff_mode ~ ' ' ~ _act_max -%}
        {%- do _result.update({'where_clause': _where, 'key_expr': _key_expr}) -%}
      {%- endif -%}
    {%- endif -%}

  {%- endif -%}

  {{ return(_result) }}
{% endmacro %}


