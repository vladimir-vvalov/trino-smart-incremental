{#-- Router: routes incremental strategy to the appropriate si_* macro --#}
{% macro get_incremental_sql(incremental_strategy, arg_dict) %}
  {%- if incremental_strategy in ('delete+insert', 'append', 'default') -%}
    {{ smart_incremental.get_delete_insert_sql(arg_dict) }}
  {%- elif incremental_strategy == 'merge' -%}
    {{ smart_incremental.get_merge_sql(arg_dict) }}
  {%- elif incremental_strategy == 'microbatch' -%}
    {{ get_incremental_microbatch_sql(arg_dict) }}
  {%- else -%}
    {%- set msg -%}
      smart_incremental: unknown incremental_strategy '{{ incremental_strategy }}'.
      Supported: append, delete+insert, merge, microbatch, default.
    {%- endset -%}
    {%- do exceptions.raise_compiler_error(msg) -%}
  {%- endif -%}
{% endmacro %}


{#-- Dispatch for DELETE+INSERT incremental strategy --#}
{% macro get_delete_insert_sql(arg_dict) -%}
{{ adapter.dispatch('get_delete_insert_sql', 'smart_incremental')(arg_dict) }}
{%- endmacro %}

{% macro trino__get_delete_insert_sql(arg_dict) -%}
    {%- set target = arg_dict['target_relation'] -%}
    {%- set source = arg_dict['temp_relation'] -%}
    {%- set dest_columns = arg_dict['dest_columns'] -%}
    {%- set incremental_predicates = arg_dict['incremental_predicates'] -%}
    {%- set where_clause = arg_dict['key_conditions']['where_clause'] -%}
    {%- set dest_cols_csv = get_quoted_csv(dest_columns | map(attribute="name")) -%}

    {%- if where_clause -%}
        delete from {{ target }}
        where {{ where_clause }}
        {%- if incremental_predicates -%}
            {% for predicate in incremental_predicates %}
                and {{ predicate }}
            {% endfor %}
        {%- endif -%};
    {%- endif %}

    insert into {{ target }} ({{ dest_cols_csv }})
    (
        select {{ dest_cols_csv }}
        from {{ source }}
    )
{%- endmacro %}


{#-- Dispatch for MERGE incremental strategy --#}
{% macro get_merge_sql(arg_dict) -%}
{{ adapter.dispatch('get_merge_sql', 'smart_incremental')(arg_dict) }}
{%- endmacro %}

{% macro trino__get_merge_sql(arg_dict) -%}
    {%- set target = arg_dict['target_relation'] -%}
    {%- set source = arg_dict['temp_relation'] -%}
    {%- set unique_key = arg_dict['unique_key'] -%}
    {%- set dest_columns = arg_dict['dest_columns'] -%}
    {%- set incremental_predicates = arg_dict['incremental_predicates'] -%}
    {%- set si_update_predicates = arg_dict.get('si_update_predicates') -%}
    {%- set predicates = [] if incremental_predicates is none else [] + incremental_predicates -%}
    {%- set dest_cols_csv = get_quoted_csv(dest_columns | map(attribute="name")) -%}
    {%- set dest_cols_csv_source = dest_cols_csv.split(', ') -%}
    {%- set merge_update_columns = config.get('merge_update_columns') -%}
    {%- set merge_exclude_columns = config.get('merge_exclude_columns') -%}
    {%- set update_columns = get_merge_update_columns(merge_update_columns, merge_exclude_columns, dest_columns) -%}
    {%- set sql_header = config.get('sql_header', none) -%}

    {#-- Normalise si_update_predicates to a list --#}
    {%- if si_update_predicates is string -%}
        {%- set si_update_predicates = [si_update_predicates] -%}
    {%- elif not si_update_predicates -%}
        {%- set si_update_predicates = [] -%}
    {%- endif -%}

    {% if unique_key %}
        {% if unique_key is sequence and unique_key is not mapping and unique_key is not string %}
            {% for key in unique_key %}
                {% set this_key_match %}
                    DBT_INTERNAL_SOURCE.{{ key }} = DBT_INTERNAL_DEST.{{ key }}
                {% endset %}
                {% do predicates.append(this_key_match) %}
            {% endfor %}
        {% else %}
            {% set unique_key_match %}
                DBT_INTERNAL_SOURCE.{{ unique_key }} = DBT_INTERNAL_DEST.{{ unique_key }}
            {% endset %}
            {% do predicates.append(unique_key_match) %}
        {% endif %}

        {{ sql_header if sql_header is not none }}

        merge into {{ target }} as DBT_INTERNAL_DEST
            using {{ source }} as DBT_INTERNAL_SOURCE
            on {{"(" ~ predicates | join(") and (") ~ ")"}}

        {% if unique_key %}
        when matched
        {%- if si_update_predicates %} and ({{ si_update_predicates | join(') and (') }}){%- endif %}
        then update set
            {% for column_name in update_columns -%}
                {{ column_name }} = DBT_INTERNAL_SOURCE.{{ column_name }}
                {%- if not loop.last %}, {%- endif %}
            {%- endfor %}
        {% endif %}

        when not matched then insert
            ({{ dest_cols_csv }})
        values
            ({% for dest_cols in dest_cols_csv_source -%}
                DBT_INTERNAL_SOURCE.{{ dest_cols }}
                {%- if not loop.last %}, {% endif %}
            {%- endfor %})

    {% else %}
        insert into {{ target }} ({{ dest_cols_csv }})
        (
            select {{ dest_cols_csv }}
            from {{ source }}
        )
    {% endif %}
{% endmacro %}

