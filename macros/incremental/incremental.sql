{% materialization smart_incremental, adapter='trino', supported_languages=['sql'] -%}

  {#-- configs: standard dbt --#}
  {%- set unique_key = config.get('unique_key') -%}
  {%- set full_refresh_mode = (should_full_refresh()) -%}
  {%- set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') -%}
  {%- set language = model['language'] -%}
  {%- set incremental_strategy = config.get('incremental_strategy') or 'default' -%}
  {#-- 'skip' is only meaningful for the full-rebuild `table` strategy (vanilla `table` supports it).
       For the delta strategies we keep the historical set rename/drop/replace. --#}
  {%- set _allowed_on_table_exists = ['rename', 'drop', 'replace', 'skip'] if incremental_strategy == 'table' else ['rename', 'drop', 'replace'] -%}
  {%- set on_table_exists = smart_incremental.si_get_metaconfig('on_table_exists', 'rename') -%}
  {% if on_table_exists not in _allowed_on_table_exists %}
      {%- do log('Invalid value for on_table_exists (%s) specified. Setting default value (%s).' % (on_table_exists, 'rename')) -%}
      {%- set on_table_exists = 'rename' -%}
  {% endif %}
  {#-- --full-refresh must always rebuild the table. `on_table_exists='skip'`
       (CREATE TABLE IF NOT EXISTS) would leave an existing table untouched, so a
       full refresh could never actually refresh it. Vanilla dbt-trino misses this;
       we fix it in smart_incremental only: force 'rename' under full refresh. --#}
  {% if full_refresh_mode and on_table_exists == 'skip' %}
      {%- do log("(smart_incremental): on_table_exists='skip' is ignored under --full-refresh; using 'rename' to rebuild the table.") -%}
      {%- set on_table_exists = 'rename' -%}
  {% endif %}
  {%- set incremental_predicates = config.get('predicates', none) or config.get('incremental_predicates', none) -%}
  {%- if incremental_predicates is string -%}
      {%- set incremental_predicates = [incremental_predicates] -%}
  {%- elif not incremental_predicates -%}
      {%- set incremental_predicates = [] -%}
  {%- else -%}
      {%- set incremental_predicates = [] + incremental_predicates -%}
  {%- endif -%}
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
      {%- do exceptions.raise_compiler_error("(smart_incremental): invalid value for si_mode: '%s'. Allowed values: 'in', 'between', '>', '>=', '<', '<='." % si_mode) -%}
  {% endif %}
  {% if si_mode and si_mode is not none and si_key | length == 0 %}
      {%- do exceptions.raise_compiler_error("(smart_incremental): si_mode is set to '%s' but si_key (or unique_key) is not defined." % si_mode) -%}
  {% endif %}
  {%- set si_min = config.get('si_min', none) -%}
  {%- set si_max = config.get('si_max', none) -%}
  {%- set si_compare = config.get('si_compare', false) -%}
  {% if si_compare not in [true, false] %}
      {%- do log('Invalid value for si_compare (%s) specified. Setting default value (%s).' % (si_compare, false)) -%}
      {%- set si_compare = false -%}
  {% endif %}
  {%- set si_compare_columns = config.get('si_compare_columns') -%}
  {% if si_compare_columns is not none and si_compare_columns and (si_compare_columns is string or si_compare_columns is not iterable) %}
      {%- do exceptions.raise_compiler_error("(smart_incremental): si_compare_columns must be a list, got: " ~ si_compare_columns) -%}
  {% endif %}
  {%- set si_exclude_compare_columns = config.get('si_exclude_compare_columns') -%}
  {% if si_exclude_compare_columns is not none and si_exclude_compare_columns and (si_exclude_compare_columns is string or si_exclude_compare_columns is not iterable) %}
      {%- do exceptions.raise_compiler_error("(smart_incremental): si_exclude_compare_columns must be a list, got: " ~ si_exclude_compare_columns) -%}
  {% endif %}
  {%- set si_update_predicates = config.get('si_update_predicates', none) -%}
  {%- if si_update_predicates is string -%}
      {%- set si_update_predicates = [si_update_predicates] -%}
  {%- elif not si_update_predicates -%}
      {%- set si_update_predicates = [] -%}
  {%- else -%}
      {%- set si_update_predicates = [] + si_update_predicates -%}
  {%- endif -%}
  {%- set si_null_key = config.get('si_null_key', 'warn') -%}
  {% if si_null_key not in ['warn', 'error', 'ignore'] %}
      {%- do log('Invalid value for si_null_key (%s) specified. Setting default value (%s).' % (si_null_key, 'warn')) -%}
      {%- set si_null_key = 'warn' -%}
  {% endif %}

  {#-- si_check_update: skip the run when {{ this }} is already newer than all sources.
       Custom keys are read via si_get_metaconfig (config.meta first) to stay clear of
       CustomKeyInConfigDeprecation on dbt-core 1.11+. --#}
  {%- set si_check_update = smart_incremental.si_get_metaconfig('si_check_update', false) -%}
  {% if si_check_update not in [true, false] %}
      {%- do log('Invalid value for si_check_update (%s) specified. Setting default value (%s).' % (si_check_update, false)) -%}
      {%- set si_check_update = false -%}
  {% endif %}
  {%- set si_missing_committed = smart_incremental.si_get_metaconfig('si_missing_committed', 'changed') -%}
  {% if si_missing_committed not in ['changed', 'unchanged'] %}
      {%- do log("Invalid value for si_missing_committed (%s) specified. Setting default value (%s)." % (si_missing_committed, 'changed')) -%}
      {%- set si_missing_committed = 'changed' -%}
  {% endif %}
  {#-- si_check_ignore: flat list of dbt-style labels (source: '<source_name>.<table>',
       model/seed/snapshot: '<name>') to exclude from the freshness comparison. --#}
  {%- set si_check_ignore = smart_incremental.si_get_metaconfig('si_check_ignore', none) -%}
  {%- if si_check_ignore is string -%}
      {%- set si_check_ignore = [si_check_ignore] -%}
  {%- elif not si_check_ignore -%}
      {%- set si_check_ignore = [] -%}
  {%- elif si_check_ignore is not iterable -%}
      {%- do exceptions.raise_compiler_error("(smart_incremental): si_check_ignore must be a string or a list, got: " ~ si_check_ignore) -%}
  {%- else -%}
      {%- set si_check_ignore = [] + si_check_ignore -%}
  {%- endif -%}

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

  {#-- ── si_check_update: decide whether this incremental run can be skipped ──────────
       Evaluated BEFORE pre_hooks on purpose. A pre_hook that mutates the target
       (e.g. `delete from {{ this }} ...`) commits a fresh Iceberg snapshot, which
       would bump the target's `committed_at` and make the freshness check see the
       table as newer than its sources → skip forever. So we decide skip first,
       using the source/target snapshots as they stand at the start of the run.

       Only evaluated on a genuine incremental run of an EXISTING table:
         - not the first run (existing_relation is not none, not a view)
         - not a full refresh
         - not the `microbatch` strategy (its batching is author-controlled)
         - not `table` + on_table_exists='skip' (nothing would be rewritten anyway)
       When true, we skip pre_hooks, run a no-op `main`, and touch nothing else. --#}
  {%- set _si_skip = false -%}
  {% if si_check_update
        and incremental_strategy != 'microbatch'
        and existing_relation is not none
        and not existing_relation.is_view
        and not full_refresh_mode
        and not (incremental_strategy == 'table' and on_table_exists == 'skip') %}
      {%- set _si_sources = smart_incremental.resolve_source_tables(ignore=si_check_ignore) -%}

      {#-- File-only log (info=false): a copy-paste-ready hint for authors. The dbt-style
           labels printed here can be dropped straight into `si_check_ignore`. Costs no
           extra queries — just walks the already-resolved list in memory. --#}
      {%- set _checked_labels = _si_sources | map(attribute='label') | list -%}
      {% do log(
          "(smart_incremental) si_check_update [" ~ this.identifier ~ "]"
          ~ "\n  checking: " ~ (_checked_labels | join(', ') if _checked_labels else '(none)')
          ~ ("\n  ignored:  " ~ (si_check_ignore | join(', ')) if si_check_ignore else ''),
          info=false
      ) %}

      {%- set _si_skip = smart_incremental.si_should_skip_update(this, _si_sources, si_missing_committed) -%}
  {% endif %}

  {#-- pre_hooks run only when we are NOT skipping. On skip the whole run is a no-op,
       so side-effecting hooks (which may mutate {{ this }}) must not fire. --#}
  {% if not _si_skip %}
    {{ run_hooks(pre_hooks) }}
  {% endif %}

  {% if _si_skip %}
    {#-- No-op main: a pure SELECT that reads and writes nothing, so the target
         table (data and Iceberg snapshots alike) is left completely untouched and
         its `committed_at` stays honest. `select 1 where false` is a valid `main`
         statement for dbt (a query runs, a result is produced) but issues no
         DDL/DML against the target. Combined with skipping pre_hooks above, a
         skipped run commits nothing to the table. --#}
    {%- call statement('main') -%}
      select 1 where false
    {%- endcall -%}

  {% elif existing_relation is none %}
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

  {% elif incremental_strategy == 'table' %}
    {#-- Full-rebuild strategy: behaves exactly like the vanilla dbt-trino `table`
         materialization. No temp relation, no delta — rewrite the whole table using
         the same `on_table_exists_logic` helper (rename/drop/replace/skip). --#}
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
          'key_conditions': key_conditions,
          'merge_update_columns': merge_update_columns,
          'merge_exclude_columns': merge_exclude_columns
    }) %}
    {%- call statement('main') -%}
      {{ smart_incremental.get_incremental_sql(incremental_strategy, strategy_arg_dict) }}
    {%- endcall -%}

    {#-- Only the delta path creates a temp relation, so only drop it here.
         The `table` / full-refresh / first-run / view / skip branches never create
         __dbt_tmp — dropping it there was a wasted metastore round-trip. --#}
    {% do drop_relation_if_exists(tmp_relation) %}
  {% endif %}
  {{ run_hooks(post_hooks) }}

  {% set should_revoke =
   should_revoke(existing_relation.is_table, full_refresh_mode) %}
  {% do apply_grants(target_relation, grant_config, should_revoke=should_revoke) %}

  {% do persist_docs(target_relation, model) %}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}