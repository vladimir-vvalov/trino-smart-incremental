{#--
  si_should_skip_update(this_relation, source_relations, si_missing_committed='changed')

  Decides whether an incremental run can be SKIPPED because the target model
  ({{ this }}) is already newer than every one of its source tables.

  Freshness signal:
    Apache Iceberg exposes a per-table metadata table `<table>$snapshots`; its
    `committed_at` column marks when each snapshot became current. The latest
    state of a table is `max(committed_at)`.

  Decision (all comparisons done inside Trino, values are UTC):
    skip  ⟺  max(committed_at of this)  >  max(committed_at of ALL sources)
    i.e. this was written strictly after the newest source change → nothing
    upstream changed since → no need to rebuild.

  Missing / NULL handling:
    - If `this` has no resolvable `committed_at` (no `$snapshots` / NULL) → NEVER skip
      (sources are treated as more recent; safest).
    - If a SOURCE has no resolvable `committed_at`, behaviour is controlled by
      `si_missing_committed`:
        'changed'   (default) → treat that source as just-changed → do NOT skip.
        'unchanged'           → ignore that source in the comparison.
    - Source existence is checked via check_relation (cache-first, cheap). A source
      whose base table does not yet exist is treated as "missing committed".

  Query economy:
    When all sources have snapshots and `this` exists, the whole comparison is a
    SINGLE Trino query returning one boolean row. Source `$snapshots` reads are
    metadata-only and each sub-select is single-row (max()).

  Params:
    this_relation        – target Relation (usually `this`)
    source_relations     – list of dicts {database, schema, identifier}
                           (as returned by resolve_source_tables())
    si_missing_committed – 'changed' (default) | 'unchanged'

  Returns:
    true  → caller should SKIP the update
    false → caller should run the update normally
--#}
{% macro si_should_skip_update(this_relation, source_relations, si_missing_committed='changed') %}
    {{ return(adapter.dispatch('si_should_skip_update', 'smart_incremental')(this_relation, source_relations, si_missing_committed)) }}
{% endmacro %}


{% macro trino__si_should_skip_update(this_relation, source_relations, si_missing_committed='changed') %}

    {#-- parse time: never skip --#}
    {% if not execute %}
        {{ return(false) }}
    {% endif %}

    {#-- normalise missing policy --#}
    {% set _missing = si_missing_committed if si_missing_committed in ('changed', 'unchanged') else 'changed' %}

    {#-- no sources at all → cannot prove staleness safely → do not skip --#}
    {% if not source_relations or source_relations | length == 0 %}
        {% do log("(smart_incremental) si_check_update: no source tables resolved; running update.", info=false) %}
        {{ return(false) }}
    {% endif %}

    {#-- `this` must exist to read its $snapshots; if not, do not skip --#}
    {% if not smart_incremental.check_relation(this_relation) %}
        {{ return(false) }}
    {% endif %}

    {#-- Partition sources into "readable" / "missing".
         Freshness metadata table depends on the source's declared format
         (meta `si_table_format`; default 'iceberg'):
             iceberg  → `<id>$snapshots`.max(committed_at)
             delta    → `<id>$history`.max(timestamp)
             unknown  → no way to read a change timestamp → always "missing"
         A source is also "missing" if its base table does not exist. Missing
         sources are handled by `si_missing_committed` (no metadata query issued). --#}
    {% set _existing_sources = [] %}
    {% set _has_missing = namespace(val=false) %}
    {% for _src in source_relations %}
        {% set _fmt = _src.get('table_format', 'iceberg') %}
        {% set _rel = api.Relation.create(
            database=_src.database, schema=_src.schema, identifier=_src.identifier
        ) %}
        {% if _fmt == 'unknown' or not smart_incremental.check_relation(_rel) %}
            {% set _has_missing.val = true %}
        {% else %}
            {% do _existing_sources.append(_src) %}
        {% endif %}
    {% endfor %}

    {#-- Missing source under 'changed' policy → treat as just-changed → do NOT skip.
         (no data query issued at all) --#}
    {% if _has_missing.val and _missing == 'changed' %}
        {% do log("(smart_incremental) si_check_update: a source has no readable change timestamp (missing table / si_table_format='none') and si_missing_committed='changed'; running update.", info=false) %}
        {{ return(false) }}
    {% endif %}

    {#-- 'unchanged' policy dropped the missing sources; if none remain → do not skip --#}
    {% if _existing_sources | length == 0 %}
        {{ return(false) }}
    {% endif %}

    {#-- Build the single comparison query.
         this_max  = max(committed_at) of this$snapshots
         src_max   = max over each source's max(committed_at)
         should_skip = this_max > src_max
         NULL propagation: if this_max is NULL → comparison is NULL → coalesce to false. --#}
    {% set _this_snap = smart_incremental.si_snapshots_relation(this_relation) %}

    {% set _src_selects = [] %}
    {% for _src in _existing_sources %}
        {% set _rel = api.Relation.create(
            database=_src.database, schema=_src.schema, identifier=_src.identifier
        ) %}
        {% set _fmt = _src.get('table_format', 'iceberg') %}
        {% do _src_selects.append(smart_incremental.si_freshness_select(_rel, _fmt)) %}
    {% endfor %}

    {% set _query %}
        select coalesce(
            (
                (select max("committed_at") from {{ _this_snap }})
                >
                (select max(m) from (
                    {{ _src_selects | join('\n                    union all\n                    ') }}
                ) as _si_src)
            ),
            false
        ) as should_skip
    {% endset %}

    {% set _res = run_query(_query) %}
    {% if _res and _res.rows | length > 0 %}
        {% set _skip = _res.rows[0][0] %}
        {% if _skip is sameas true %}
            {#-- File-only (info=false → DEBUG → written to logs/dbt.log, not the terminal).
                 In the terminal the run status alone tells the story: `SUCCESS` means the
                 update was skipped by si_check_update; `CREATE TABLE (N rows)` means a real write. --#}
            {% do log("(smart_incremental) si_check_update: target is newer than all sources; SKIPPING update for " ~ this_relation ~ ".", info=false) %}
            {{ return(true) }}
        {% endif %}
    {% endif %}

    {{ return(false) }}

{% endmacro %}


{#--
  si_snapshots_relation(relation)

  Builds a Trino-quoted reference to the Iceberg metadata table
  `<identifier>$snapshots` in the same database/schema as `relation`:

      "database"."schema"."identifier$snapshots"

  The `$snapshots` suffix is appended to the identifier inside the quoted part,
  which is the form Trino's Iceberg connector expects.
--#}
{% macro si_snapshots_relation(relation) %}
    {%- set _db = relation.database -%}
    {%- set _schema = relation.schema -%}
    {%- set _id = relation.identifier -%}
    {{- '"' ~ _db ~ '"."' ~ _schema ~ '"."' ~ _id ~ '$snapshots"' -}}
{% endmacro %}


{#--
  si_freshness_select(relation, table_format)

  Builds a single-row `select ... as m` that returns the last-change timestamp
  of `relation`, reading the cheap metadata table for its format:

    iceberg (default) → select max("committed_at") as m from "<db>"."<sch>"."<id>$snapshots"
    delta             → select max("timestamp")    as m from "<db>"."<sch>"."<id>$history"

  `$snapshots` (Iceberg) and `$history` (Delta Lake) are metadata-only tables, so
  these reads do not scan data. The result column is always aliased `m` so the
  caller can UNION ALL sources of mixed formats and take a global max(m).

  Params:
    relation     – source Relation
    table_format – 'iceberg' (default) | 'delta'
--#}
{% macro si_freshness_select(relation, table_format='iceberg') %}
    {%- set _db = relation.database -%}
    {%- set _schema = relation.schema -%}
    {%- set _id = relation.identifier -%}
    {%- set _fmt = table_format if table_format in ('iceberg', 'delta') else 'iceberg' -%}
    {%- if _fmt == 'delta' -%}
        {{- 'select max("timestamp") as m from "' ~ _db ~ '"."' ~ _schema ~ '"."' ~ _id ~ '$history"' -}}
    {%- else -%}
        {{- 'select max("committed_at") as m from "' ~ _db ~ '"."' ~ _schema ~ '"."' ~ _id ~ '$snapshots"' -}}
    {%- endif -%}
{% endmacro %}
