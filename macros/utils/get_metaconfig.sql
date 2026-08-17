{#--
  si_get_metaconfig(key, default)

  Version-safe config accessor for cross-compatibility across dbt-core 1.10 / 1.11 / 1.12.

  Background:
    dbt-core 1.11+ raises CustomKeyInConfigDeprecation for non-official config keys
    placed at the top level of `config` (e.g. in dbt_project.yml). The remediation is
    to move such keys under `config.meta`. However:
      - `config.get(key)` does NOT read `meta` on all versions (returns None once moved);
      - `config.meta_get(key)` only exists in dbt-core 1.12+.

  This macro resolves a key regardless of placement, without relying on meta_get:
    1. look in `config.meta` first (isolated namespace, collision-safe);
    2. fall back to top-level `config.get(key, default)` (legacy placement).

  Works on dbt-core 1.10 / 1.11 / 1.12, and whether the key lives in `meta`
  or at the top level of `config`.

  Params:
    key      – config key name to resolve
    default  – value returned when the key is found in neither meta nor top-level
--#}
{% macro si_get_metaconfig(key, default=none) %}
    {%- set _meta = config.get('meta', {}) or {} -%}
    {%- if key in _meta -%}
        {{ return(_meta[key]) }}
    {%- else -%}
        {{ return(config.get(key, default)) }}
    {%- endif -%}
{% endmacro %}
