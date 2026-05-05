{#--
  check_relation(relation, use_cache)
  Wrapper: checks whether a relation exists by relation object.
  Delegates to check_table.
--#}
{% macro check_relation(relation=this, use_cache=none) %}
    {{ return(smart_incremental.check_table(
        model_name = relation.identifier,
        schema_name = relation.schema,
        database_name = relation.database,
        use_cache = use_cache
    )) }}
{% endmacro %}


{#--
  check_table(model_name, schema_name, database_name, use_cache)
  Dispatcher: checks whether a table exists by name/schema/database.
    use_cache=true  — cache only (adapter.get_relation)
    use_cache=false — DB only (information_schema query)
    use_cache=none  — cache first, DB on miss  [default]
--#}
{% macro check_table(model_name=model.name, schema_name=model.schema, database_name=model.database, use_cache=none) %}
    {{ return(adapter.dispatch('check_table', 'smart_incremental')(model_name, schema_name, database_name, use_cache)) }}
{% endmacro %}

{% macro trino__check_table(model_name=model.name, schema_name=model.schema, database_name=model.database, use_cache=none) %}

    {#-- compile-time: nothing to check --#}
    {% if not execute %}
        {{ return(false) }}
    {% endif %}

    {#-- catalog existence check: only for non-target databases --#}
    {% if database_name != model.database %}
        {% set catalog_check_query %}
            select 1 as "result"
            from "system"."metadata"."catalogs"
            where "catalog_name" = '{{ database_name }}'
            limit 1
        {% endset %}
        {% if run_query(catalog_check_query).rows | length == 0 %}
            {{ return(false) }}
        {% endif %}
    {% endif %}

    {#-- cache lookup --#}
    {% if use_cache is sameas true or use_cache is none %}
        {% set cached = adapter.get_relation(
            database = database_name,
            schema = schema_name,
            identifier = model_name
        ) %}
        {% if cached is not none and cached %}
            {{ return(true) }}
        {% endif %}
        {#-- cache-only: miss → not found --#}
        {% if use_cache is sameas true %}
            {{ return(false) }}
        {% endif %}
    {% endif %}

    {#-- DB query (use_cache=false, or none after cache miss) --#}
    {% set result = false %}
    {% set query %}
        select 1 as "result"
        from "{{ database_name }}"."information_schema"."tables"
        where "table_schema" = '{{ schema_name }}'
          and "table_name"   = '{{ model_name }}'
        limit 1
    {% endset %}
    {% if run_query(query).rows | length > 0 %}
        {% set result = true %}
    {% endif %}
    {{ return(result) }}

{% endmacro %}
