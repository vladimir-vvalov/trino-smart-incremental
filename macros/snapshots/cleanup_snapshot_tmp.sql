{% macro cleanup_snapshot_tmp() %}
    {%- set tmp_relation = make_temp_relation(this) -%}
    DROP TABLE IF EXISTS {{ tmp_relation }}
{%- endmacro %}
