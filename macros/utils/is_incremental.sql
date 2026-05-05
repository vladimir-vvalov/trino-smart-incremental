{#--
  is_incremental(use_cache)
  Returns true when the model should run incrementally:
    - relation already exists in DB (via check_relation)
    - no full refresh requested
    - model materialization is 'smart_incremental'
--#}
{% macro is_incremental(use_cache=none) %}
    {% if model.config.materialized == 'smart_incremental'
            and not should_full_refresh()
            and smart_incremental.check_relation(this, use_cache=use_cache) %}
        {{ return(true) }}
    {% endif %}
    {{ return(false) }}
{% endmacro %}
