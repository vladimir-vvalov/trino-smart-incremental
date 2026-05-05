{% materialization smart_incremental, adapter='trino', supported_languages=['sql'] -%}

  {#-- configs: standard dbt --#}
  {%- set unique_key = config.get('unique_key') -%}
  {%- set full_refresh_mode = (should_full_refresh()) -%}
  {%- set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') -%}
  {%- set language = model['language'] -%}
  {%- set on_table_exists = config.get('on_table_exists', 'rename') -%}
  {% if on_table_exists not in ['rename', 'drop', 'replace'] %}
      {%- set log_message = 'Invalid value for on_table_exists (%s) specified. Setting default value (%s).' % (on_table_exists, 'rename') -%}
      {% do log(log_message) %}
      {%- set on_table_exists = 'rename' -%}
  {% endif %}
  {%- set incremental_strategy = config.get('incremental_strategy') or 'default' -%}
  {%- set incremental_predicates = config.get('predicates', none) or config.get('incremental_predicates', none) -%}
  {%- set merge_update_columns = config.get('merge_update_columns') -%}
  {%- set merge_exclude_columns = config.get('merge_exclude_columns') -%}

  {#-- configs: si_incremental --#}
  {%- set raw_si_key = config.get('si_key') -%}
  {% if (not raw_si_key or raw_si_key is none) and unique_key and incremental_strategy == 'delete+insert' %}
      {%- set raw_si_key = unique_key -%}
  {% endif %}
  {%- if not raw_si_key or raw_si_key is none -%}
      {%- set si_key = [] -%}
  {%- elif raw_si_key is iterable and raw_si_key is not string -%}
      {%- set si_key = raw_si_key -%}
  {%- else -%}
      {%- set si_key = [raw_si_key] -%}
  {%- endif -%}

  {%- set si_mode = config.get('si_mode') -%}
  {% if si_mode and si_mode is not none and si_mode not in ['in', 'between', '>', '>=', '<', '<='] %}
      {%- set error_message = "smart_incremental: invalid value for si_mode: '%s'. Allowed values: 'in', 'between', '>', '>=', '<', '<='." % si_mode -%}
      {%- do exceptions.raise_compiler_error(error_message) -%}
  {% endif %}
  {%- set si_min = si_min if si_min is not none and si_min else none -%}
  {%- set si_max = si_max if si_max is not none and si_max else none -%}
  {%- set si_compare = config.get('si_compare', false) -%}
  {% if si_compare not in [true, false] %}
      {%- set log_message = 'Invalid value for si_compare (%s) specified. Setting default value (%s).' % (si_compare, false) -%}
      {% do log(log_message) %}
      {%- set si_compare = false -%}
  {% endif %}
  {%- set si_compare_columns = config.get('si_compare_columns') -%}
  {% if si_compare_columns is not none and si_compare_columns and (si_compare_columns is string or si_compare_columns is not iterable) %}
      {%- do exceptions.raise_compiler_error("smart_incremental: si_compare_columns must be a list, got: " ~ si_compare_columns) -%}
  {% endif %}
  {%- set si_exclude_compare_columns = config.get('si_exclude_compare_columns') -%}
  {% if si_exclude_compare_columns is not none and si_exclude_compare_columns and (si_exclude_compare_columns is string or si_exclude_compare_columns is not iterable) %}
      {%- do exceptions.raise_compiler_error("smart_incremental: si_exclude_compare_columns must be a list, got: " ~ si_exclude_compare_columns) -%}
  {% endif %}
  {%- set si_update_predicates = config.get('si_update_predicates', none) -%}
  {%- set si_null_key = config.get('si_null_key', 'warn') -%}
  {% if si_null_key not in ['warn', 'error', 'ignore'] %}
      {%- set log_message = 'Invalid value for si_null_key (%s) specified. Setting default value (%s).' % (si_null_key, 'warn') -%}
      {% do log(log_message) %}
      {%- set si_null_key = 'warn' -%}
  {% endif %}

  {#-- relations --#}
  {%- set existing_relation = load_cached_relation(this) -%}
  {%- set target_relation = this.incorporate(type='table') -%}
  {#-- The temp relation will be a view (faster) or temp table, depending on upsert/merge strategy --#}
  {%- set tmp_relation_type = smart_incremental.get_incremental_tmp_relation_type(incremental_strategy, si_key, language) -%}
  {%- set tmp_relation = make_temp_relation(this).incorporate(type=tmp_relation_type) -%}
  {%- set intermediate_relation = make_intermediate_relation(target_relation) -%}
  {%- set backup_relation_type = 'table' if existing_relation is none else existing_relation.type -%}
  {%- set backup_relation = make_backup_relation(target_relation, backup_relation_type) -%}

  {#-- the temp_ and backup_ relation should not already exist in the database; get_relation
  -- will return None in that case. Otherwise, we get a relation that we can drop
  -- later, before we try to use this name for the current operation.#}
  {%- set preexisting_tmp_relation = load_cached_relation(tmp_relation)-%}
  {%- set preexisting_intermediate_relation = load_cached_relation(intermediate_relation)-%}
  {%- set preexisting_backup_relation = load_cached_relation(backup_relation) -%}

  {#--- grab current tables grants config for comparision later on#}
  {% set grant_config = config.get('grants') %}

  -- drop the temp relations if they exist already in the database
  {{ drop_relation_if_exists(preexisting_tmp_relation) }}
  {{ drop_relation_if_exists(preexisting_intermediate_relation) }}
  {{ drop_relation_if_exists(preexisting_backup_relation) }}

  {{ run_hooks(pre_hooks) }}

  {% if existing_relation is none %}
    {%- call statement('main', language=language) -%}
      {{ create_table_as(False, target_relation, compiled_code, language) }}
    {%- endcall -%}

  {% elif existing_relation.is_view %}
    {#-- Can't overwrite a view with a table - we must drop --#}
    {{ log("Dropping relation " ~ target_relation ~ " because it is a view and this model is a table.") }}
    {% do adapter.drop_relation(existing_relation) %}
    {%- call statement('main', language=language) -%}
      {{ create_table_as(False, target_relation, compiled_code, language) }}
    {%- endcall -%}
  {% elif full_refresh_mode %}
    {#-- Create table with given `on_table_exists` mode #}
    {% do on_table_exists_logic(on_table_exists, existing_relation, intermediate_relation, backup_relation, target_relation) %}

  {% else %}
    {#-- Create the temp relation, either as a view or as a temp table --#}
    {% if tmp_relation_type == 'view' %}
        {%- call statement('create_tmp_relation') -%}
          {{ create_view_as(tmp_relation, compiled_code) }}
        {%- endcall -%}
    {% else %}
        {%- call statement('create_tmp_relation', language=language) -%}
          {{ create_table_as(True, tmp_relation, compiled_code, language) }}
        {%- endcall -%}
    {% endif %}

    {% do adapter.expand_target_column_types(
           from_relation=tmp_relation,
           to_relation=target_relation) %}
    {#-- Process schema changes. Returns dict of changes if successful. Use source columns for upserting/merging --#}
    {% set dest_columns = process_schema_changes(on_schema_change, tmp_relation, existing_relation) %}
    {% if not dest_columns %}
      {% set dest_columns = adapter.get_columns_in_relation(existing_relation) %}
    {% endif %}

    {#-- Build key conditions (reads tmp_relation, returns where_clause + key_expr) --#}
    {%- set key_conditions = smart_incremental.get_key_conditions(
          tmp_relation = tmp_relation,
          unique_key = unique_key,
          incremental_strategy = incremental_strategy,
          si_key = si_key,
          si_mode = si_mode,
          si_min = si_min,
          si_max = si_max,
          si_null_key = si_null_key,
          dest_columns = dest_columns
    ) -%}

    {#-- Build the sql --#}
    {% set strategy_arg_dict = ({
          'target_relation': target_relation,
          'temp_relation': tmp_relation,
          'unique_key': unique_key,
          'si_key': si_key,
          'dest_columns': dest_columns,
          'incremental_predicates': incremental_predicates,
          'si_update_predicates': si_update_predicates,
          'key_conditions': key_conditions
    }) %}
    {%- call statement('main') -%}
      {{ smart_incremental.get_incremental_sql(incremental_strategy, strategy_arg_dict) }}
    {%- endcall -%}
  {% endif %}
    {% do drop_relation_if_exists(tmp_relation) %}
  {{ run_hooks(post_hooks) }}

  {% set should_revoke =
   should_revoke(existing_relation.is_table, full_refresh_mode) %}
  {% do apply_grants(target_relation, grant_config, should_revoke=should_revoke) %}

  {% do persist_docs(target_relation, model) %}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}