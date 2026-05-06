{#--
  distinct_from_relation(relation, expression, row_name_by, conditions, is_quoting)

  Reads DISTINCT values of an expression from a relation into a nested dict.

  Generates:
    SELECT DISTINCT <expression>
    FROM <relation>
    [WHERE <cond1> AND <cond2> AND ...]

  Parameters:
    relation    - Relation object (e.g. this, ref(...), si_forward(...)); required
    expression  - SQL expression string (e.g. 'col1' or 'col1, col2'); required
    conditions  - list of WHERE condition strings; [] -> no WHERE clause
    is_quoting  - true / false / none (auto)

  Returns: list [ { column_id: value } ]
--#}
{% macro distinct_from_relation(
    relation,
    expression,
    conditions = [],
    is_quoting = none,
    col_types = none
) %}
    {% if not expression or expression is none %}
        {{ return({}) }}
    {% endif %}

    {% set _where = smart_incremental.build_where_clause(conditions) %}

    {% set _sql %}
select distinct
    {{ expression }}
from {{ relation }}
{{ _where }}
    {% endset %}

    {% set _raw = smart_incremental.values_from_query(
        relation = relation,
        sql_query = _sql,
        row_name_by = '__index__',
        is_quoting = is_quoting,
        dest_columns = col_types
    ) %}

    {#-- Post-process: {0:{col:val},...} -> [{col:val,...}, ...] --#}
    {% set _result = [] %}
    {% for _row in _raw.values() %}
        {% do _result.append(_row) %}
    {% endfor %}
    {{ return(_result) }}
{% endmacro %}


{#--
  minmax_from_relation(relation, columns, agg_type, row_name_by, conditions, is_quoting)

  Reads MIN/MAX value(s) per column from a relation into a nested dict.

  Generates (row_name_by is none / ''):
    SELECT MAX(<col1>) AS max_<col1>, ...   -- or MIN / both
    FROM <relation>
    [WHERE ...]
    -> single row with overall agg per column; result key = '__index__' (0)

  Generates (row_name_by == '__index__'):
    SELECT <col1>, <col2>, ...
    FROM <relation>
    [WHERE ...]
    -> rows as-is, no aggregation, no GROUP BY

  Generates (row_name_by == '<colname>'):
    SELECT <key_col>, MAX(<col2>) AS max_<col2>, ...
    FROM <relation>
    [WHERE ...]
    GROUP BY <key_col>
    -> one row per key value

  Parameters:
    relation    - Relation object (e.g. this, ref(...), si_forward(...)); required
    columns     - list of column names to aggregate; [] -> return {}
    agg_type    - 'max'    -> MAX only, alias max_<col>      [default]
                  'min'    -> MIN only, alias min_<col>
                  'minmax' -> both MAX and MIN as separate columns
    row_name_by - none/''         -> aggregate all columns, no GROUP BY (overall)  [default]
                  '__index__'    -> 0-based index; no aggregation, no GROUP BY
                  '<colname>'   -> named column is key, GROUP BY it; aggregate on others
    conditions  - list of WHERE condition strings; [] -> no WHERE clause
    is_quoting  - true / false / none (auto)

  Returns: dict { row_id: { column_id: value } }
--#}
{% macro minmax_from_relation(
    relation,
    columns = [],
    agg_type = 'minmax',
    row_name_by = none,
    conditions = [],
    is_quoting = none
) %}
    {% if not columns or columns | length == 0 %}
        {{ return({}) }}
    {% endif %}

    {% set _where = smart_incremental.build_where_clause(conditions) %}

    {#-- Build SELECT list and optional GROUP BY (single unified block) --#}
    {% if row_name_by == '__index__' %}
        {#-- no aggregation, no GROUP BY вЂ” pass columns through as-is --#}
        {% set _select_parts = columns %}
        {% set _group_by = '' %}
    {% else %}
        {#-- key column (none = overall max/min, string = grouped) --#}
        {% set _key_col = row_name_by if row_name_by else none %}
        {% set _select_parts = [_key_col] if _key_col else [] %}
        {% for col in columns %}
            {% if col != _key_col %}
                {# Support 'expr as alias' — split on ' as ' to separate expression from alias #}
                {%- if ' as ' in col -%}
                    {%- set _parts = col.split(' as ') -%}
                    {%- set _col_expr = _parts | first -%}
                    {%- set _col_alias = _parts | last -%}
                {%- else -%}
                    {%- set _col_expr = col -%}
                    {%- set _col_alias = col -%}
                {%- endif -%}
                {% if agg_type == 'min' %}
                    {% do _select_parts.append('min(' ~ _col_expr ~ ') as min_' ~ _col_alias) %}
                {% elif agg_type == 'max' %}
                    {% do _select_parts.append('max(' ~ _col_expr ~ ') as max_' ~ _col_alias) %}
                {% else %}
                    {% do _select_parts.append('min(' ~ _col_expr ~ ') as min_' ~ _col_alias) %}
                    {% do _select_parts.append('max(' ~ _col_expr ~ ') as max_' ~ _col_alias) %}
                {% endif %}
            {% endif %}
        {% endfor %}
        {% set _group_by = 'group by ' ~ _key_col if _key_col else '' %}
    {% endif %}

    {% set _sql %}
select
    {{ _select_parts | join(',\n    ') }}
from {{ relation }}
{{ _where }}
{{ _group_by }}
    {% endset %}

    {% set _raw = smart_incremental.values_from_query(
        relation = relation,
        sql_query = _sql,
        row_name_by = '__index__' if not row_name_by else row_name_by,
        is_quoting = is_quoting
    ) %}
    {#-- row_name_by=none: single overall-agg row вЂ” flatten {0: row_dict} -> row_dict --#}
    {% if not row_name_by %}
        {{ return(_raw.get(0, {})) }}
    {% endif %}
    {{ return(_raw) }}
{% endmacro %}


{#-- Wrapper: MAX only. See minmax_from_relation for full docs. --#}
{% macro max_from_relation(
    relation,
    columns = [],
    row_name_by = none,
    conditions = [],
    is_quoting = none
) %}
    {{ return(smart_incremental.minmax_from_relation(
        relation = relation,
        columns = columns,
        agg_type = 'max',
        row_name_by = row_name_by,
        conditions = conditions,
        is_quoting = is_quoting
    )) }}
{% endmacro %}


{#-- Wrapper: MIN only. See minmax_from_relation for full docs. --#}
{% macro min_from_relation(
    relation,
    columns = [],
    row_name_by = none,
    conditions = [],
    is_quoting = none
) %}
    {{ return(smart_incremental.minmax_from_relation(
        relation = relation,
        columns = columns,
        agg_type = 'min',
        row_name_by = row_name_by,
        conditions = conditions,
        is_quoting = is_quoting
    )) }}
{% endmacro %}


{#-- Normalises conditions to a list and builds a WHERE clause string.
  Returns '' when conditions is empty.
--#}
{% macro build_where_clause(conditions) %}
    {%- if conditions is string -%}
        {%- set conditions = [conditions] -%}
    {%- endif -%}
    {%- if conditions | length > 0 -%}
        {%- set _clause %}where
    {{ conditions | join('\n    and ') }}{%- endset -%}
        {{ return(_clause) }}
    {%- endif -%}
    {{ return('') }}
{% endmacro %}


{#--
  values_from_relation(relation, row_name_by, is_quoting)

  Reads all rows from a relation into a nested dict.
  Shortcut for values_from_query without custom SQL.

  Parameters:
    relation    - Relation object (e.g. this, ref(...), si_forward(...)); required
    row_name_by - none/''         -> first column value  [default]
                  '__index__'    -> 0-based loop index
                  '<colname>'   -> value of the named column
    is_quoting  - true / false / none (auto)

  Returns: dict { row_id: { column_id: value } }
--#}
{% macro values_from_relation(
    relation,
    row_name_by = none,
    is_quoting = none
) %}
    {{ return(smart_incremental.get_values_impl(
        relation = relation,
        row_name_by = row_name_by,
        is_quoting = is_quoting
    )) }}
{% endmacro %}


{#--
  values_from_table(table, schema, database, sql_query, row_name_by, is_quoting)

  Reads rows from a table by name into a nested dict.
  Constructs a Relation object and delegates to get_values_impl.

  Parameters:
    table       - table name; required
    schema      - schema name; required
    database    - database name; required
    sql_query   - custom SQL; if '' -> SELECT * FROM table is used
    row_name_by - none/''         -> first column value  [default]
                  '__index__'    -> 0-based loop index
                  '<colname>'   -> value of the named column
    is_quoting  - true / false / none (auto)

  Returns: dict { row_id: { column_id: value } }
--#}
{% macro values_from_table(
    table,
    schema = model.schema,
    database = model.database,
    sql_query = '',
    row_name_by = none,
    is_quoting = none
) %}
    {% set _rel = api.Relation.create(database=database, schema=schema, identifier=table) %}
    {{ return(smart_incremental.get_values_impl(
        relation = _rel,
        sql_query = sql_query,
        row_name_by = row_name_by,
        is_quoting = is_quoting
    )) }}
{% endmacro %}


{#--
  values_from_query(relation, sql_query, row_name_by, is_quoting)

  Wrapper over get_values_impl that accepts a Relation object instead of
  separate table/schema/database parameters.

  Parameters:
    relation    - Relation object (e.g. this, ref(...), si_forward(...)); required
    sql_query   - custom SQL; if '' -> SELECT * FROM relation is used
    row_name_by - none/''         -> first column value  [default]
                  '__index__'    -> 0-based loop index
                  '<colname>'   -> value of the named column
    is_quoting  - true  -> force single-quote all values
                  false -> force no quoting
                  none  -> auto

  Returns: dict { row_id: { column_id: value } }
--#}
{% macro values_from_query(
    relation,
    sql_query = '',
    row_name_by = none,
    is_quoting = none,
    dest_columns = none
) %}
    {{ return(smart_incremental.get_values_impl(
        relation = relation,
        sql_query = sql_query,
        row_name_by = row_name_by,
        is_quoting = is_quoting,
        dest_columns = dest_columns
    )) }}
{% endmacro %}


{#--
  get_values_impl(table, schema, database, sql_query, row_name_by, is_quoting)

  Dispatcher. Loads rows from a table (or arbitrary query) into a nested dict:
    { row_id: { column_id: value } }

  Parameters:
    table       - table name          (default: model.name)
    schema      - schema name         (default: model.schema)
    database    - database name       (default: model.database)
    sql_query   - custom SQL; if '' -> SELECT * FROM table is used
    row_name_by - key selection mode:
                  none / ''     -> first column value  [default]
                  '__index__'   -> 0-based loop index
                  '<colname>'   -> value of the named column
    is_quoting  - true  -> force single-quote all values
                  false -> force no quoting
                  none  -> auto: Number/Boolean unquoted, everything else quoted

  Config keys read from the model config (lower priority than parameters):
    si_in_rows_limit - max rows to fetch   (default: 1 000 000)

  Returns: dict { row_id: { column_id: value } }
--#}
{% macro get_values_impl(
    relation,
    sql_query = '',
    row_name_by = none,
    is_quoting = none,
    dest_columns = none
) %}
    {{ return(adapter.dispatch('get_values_impl', 'smart_incremental')(relation, sql_query, row_name_by, is_quoting, dest_columns)) }}
{% endmacro %}

{% macro trino__get_values_impl(
    relation,
    sql_query = '',
    row_name_by = none,
    is_quoting = none,
    dest_columns = none
) %}

    {#-- Skip if not execute --#}
    {% if not execute %}
        {{ return({}) }}
    {% endif %}

    {#-- Skip if no relation --#}
    {% if not relation %}
        {{ return({}) }}
    {% endif %}

    {#-- Skip if table does not exist --#}
    {% if not smart_incremental.check_relation(relation) %}
        {{ return({}) }}
    {% endif %}

    {#-- Row limit from config, default 1 000 000 --#}
    {% set si_in_rows_limit = config.get('si_in_rows_limit', 1000000) %}

    {#-- row_name_by: normalize вЂ” treat '' same as none (first column mode) --#}
    {% if row_name_by == '' %}
        {% set row_name_by = none %}
    {% endif %}

    {#-- validate --#}
    {% if row_name_by is not none
          and row_name_by != '__index__'
          and row_name_by | string != row_name_by %}
        {{ exceptions.raise_compiler_error(
            "get_values_impl: row_name_by must be none, '__index__', or a column name string"
        ) }}
    {% endif %}

    {#-- Build base query --#}
    {% if not sql_query %}
        {% set base_query %}
            select * from {{ relation }}
        {% endset %}
    {% else %}
        {% set base_query = sql_query %}
    {% endif %}

    {#-- Wrap in subquery to safely apply LIMIT regardless of base_query content --#}
    {% set full_query %}
        select * from (
            {{ base_query }}
        ) as _si_subq
        limit {{ si_in_rows_limit }}
    {% endset %}

    {#-- Run query --#}
    {% set results = run_query(full_query) %}

    {#-- Build result dict --#}
    {% set result_dict = {} %}

    {% if results and results.rows | length > 0 %}
        {% set col_names = results.column_names %}

        {#-- Precompute key/value layout once (constant for all rows) --#}
        {#-- key_mode: 'index' | 'first' | 'named' --#}
        {% if row_name_by == '__index__' %}
            {% set key_mode = 'index' %}
            {% set key_col  = none %}
        {% elif row_name_by is none %}
            {% set key_mode = 'first' %}
            {% set key_col  = col_names[0] %}
        {% else %}
            {% set key_mode = 'named' %}
            {% set key_col  = row_name_by %}
        {% endif %}

        {#-- value_cols: columns to include in row_dict (key column excluded unless index mode) --#}
        {% if key_mode == 'index' %}
            {% set value_cols = col_names %}
        {% else %}
            {% set value_cols = [] %}
            {% for c in col_names %}
                {% if c != key_col %}
                    {% do value_cols.append(c) %}
                {% endif %}
            {% endfor %}
        {% endif %}

        {#-- quote_mode: 'force_quote' | 'force_raw' | 'auto' (constant for all rows) --#}
        {% if is_quoting is sameas true %}
            {% set quote_mode = 'force_quote' %}
        {% elif is_quoting is sameas false %}
            {% set quote_mode = 'force_raw' %}
        {% else %}
            {% set quote_mode = 'auto' %}
        {% endif %}

        {#-- build col type lookup from dest_columns if provided, else query schema --#}
        {% set _col_types = {} %}
        {% if dest_columns is not none and dest_columns | length > 0 %}
            {% for _c in dest_columns %}
                {% do _col_types.update({_c.name: _c.data_type | lower}) %}
            {% endfor %}
        {% elif quote_mode == 'auto' %}
            {% for _c in adapter.get_columns_in_relation(relation) %}
                {% do _col_types.update({_c.name: _c.data_type | lower}) %}
            {% endfor %}
        {% endif %}

        {% for row in results.rows %}

            {#-- row_id: index / first column / named column --#}
            {% if key_mode == 'index' %}
                {% set row_id = loop.index0 %}
            {% else %}
                {#-- preserve none: do NOT convert NULL to string 'None' --#}
                {% if row[key_col] is none %}
                    {% set row_id = none %}
                {% else %}
                    {% set row_id = row[key_col] | string %}
                {% endif %}
                {% if row_id in result_dict %}
                    {{ exceptions.raise_compiler_error(
                        "get_values_impl: duplicate row_id '"
                        ~ row_id ~ "' in column '" ~ key_col ~ "'"
                    ) }}
                {% endif %}
            {% endif %}

            {#-- column dict for this row --#}
            {% set row_dict = {} %}

            {% for col_name in value_cols %}
                {% set raw_val = row[col_name] %}

                {#-- format value (branch on precomputed quote_mode) --#}
                {#-- NULL stays as none — not converted to string 'null' or 'None' --#}
                {% if raw_val is none %}
                    {% set val = none %}
                {% elif quote_mode == 'force_quote' %}
                    {% set val = "'" ~ (raw_val | string | replace("'", "''")) ~ "'" %}
                {% elif quote_mode == 'force_raw' %}
                    {% set val = raw_val | string %}
                {% else %}
                    {#-- auto: Boolean -> true/false; Number -> bare; Date/Timestamp -> typed literal; everything else -> quoted --#}
                    {% set _dtype = _col_types.get(col_name, '') %}
                    {#-- fallback: strip min_/max_ prefix for aggregated columns --#}
                    {% if not _dtype and (col_name.startswith('min_') or col_name.startswith('max_')) %}
                        {% set _dtype = _col_types.get(col_name[4:], '') %}
                    {% endif %}
                    {% if raw_val is sameas true %}
                        {% set val = 'true' %}
                    {% elif raw_val is sameas false %}
                        {% set val = 'false' %}
                    {% elif raw_val is number %}
                        {% set val = raw_val | string %}
                    {% elif _dtype == 'date' %}
                        {% set val = "DATE '" ~ (raw_val | string) ~ "'" %}
                    {% elif 'timestamp' in _dtype %}
                        {% set val = "TIMESTAMP '" ~ (raw_val | string) ~ "'" %}
                    {% else %}
                        {% set val = "'" ~ (raw_val | string | replace("'", "''")) ~ "'" %}
                    {% endif %}
                {% endif %}

                {% do row_dict.update({col_name: val}) %}
            {% endfor %}

            {% do result_dict.update({row_id: row_dict}) %}
        {% endfor %}
    {% endif %}

    {{ return(result_dict) }}

{% endmacro %}

