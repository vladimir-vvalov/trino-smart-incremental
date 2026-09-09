{#--
  resolve_source_tables(node=none, ignore=none)

  Resolves the full set of *physical source tables* that feed the given model,
  looking through ephemeral and view nodes transitively.

  Purpose:
    Used by si_check_update to know which upstream tables' `committed_at`
    (Iceberg `$snapshots`) must be compared against `{{ this }}`.

  Traversal rules (BFS over the dbt graph):
    - start from `node.depends_on.nodes` (direct upstream unique_ids)
    - `source`  node                → physical source table  (terminal)
    - `seed`    node                → physical table          (terminal)
    - `snapshot` node               → physical table          (terminal)
    - `model` node:
        - materialized in (ephemeral, view) → TRANSPARENT: descend into its
          own `depends_on.nodes` (a view/ephemeral has no meaningful
          `committed_at`; only the tables it reads matter)
        - any other materialization (table, incremental, smart_incremental,
          materialized_view, ...) → physical table (terminal)
    - other resource types → ignored

  dbt-style label (used for si_check_ignore matching and for logging):
    - source            → "<source_name>.<table_name>"   e.g. "hermes.dbo__activities"
    - model/seed/snapshot → "<name>"                      e.g. "int__lager_commodity"
    This mirrors how you reference the object in dbt (`source('hermes','dbo__activities')`
    / `ref('int__lager_commodity')`), never the physical database/schema.

  si_check_ignore (via `ignore`):
    A flat list of dbt-style labels to EXCLUDE from the freshness comparison.
    A node is dropped when its label equals any entry in `ignore`. Ignored nodes
    are removed entirely (their own upstreams are NOT descended into). Ignore
    entries that match nothing raise a warning (typo guard).

  Notes:
    - Deduplicates results by (database, schema, identifier).
    - Cycle-safe via a visited set.
    - At parse time (execute == false) returns [] (graph not populated).
    - For models/seeds/snapshots the physical identifier is `node.alias`
      (falls back to `node.name`). For sources it is `node.identifier`
      (falls back to `node.name`).

  Params:
    node   – the node to resolve sources for. Defaults to the current `model`.
    ignore – list of dbt-style labels to exclude (default none → nothing ignored).

  Returns:
    list of dicts:
      [ { 'database':..., 'schema':..., 'identifier':..., 'table_format':..., 'label':... }, ... ]
--#}
{% macro resolve_source_tables(node=none, ignore=none) %}

    {#-- parse time: graph not populated --#}
    {% if not execute %}
        {{ return([]) }}
    {% endif %}

    {% set _node = node if node is not none else model %}

    {#-- normalise ignore into a set (dict used as set) + a "matched" tracker --#}
    {% set _ignore_set = {} %}
    {% if ignore is string %}
        {% do _ignore_set.update({ignore: false}) %}
    {% elif ignore %}
        {% for _ig in ignore %}
            {% do _ignore_set.update({_ig: false}) %}
        {% endfor %}
    {% endif %}

    {#-- results keyed by "db.schema.id" for O(1) dedupe --#}
    {% set _results = {} %}
    {% set _visited = {} %}

    {#-- seed the queue with direct upstream unique_ids --#}
    {% set _queue = [] %}
    {% for _uid in (_node.depends_on.nodes or []) %}
        {% do _queue.append(_uid) %}
    {% endfor %}

    {#-- bounded loop: at most one visit per graph node --#}
    {% set _max_iter = (graph.nodes | length) + (graph.sources | length) + (_queue | length) %}

    {% for _ in range(_max_iter) %}
        {% if _queue | length > 0 %}
            {% set _uid = _queue.pop(0) %}

            {% if _uid not in _visited %}
                {% do _visited.update({_uid: true}) %}

                {#-- source node --#}
                {% if _uid in graph.sources %}
                    {% set _src = graph.sources[_uid] %}
                    {% set _label = _src.source_name ~ '.' ~ _src.name %}
                    {% if _label in _ignore_set %}
                        {% do _ignore_set.update({_label: true}) %}
                    {% else %}
                        {% set _id = _src.identifier or _src.name %}
                        {% set _key = _src.database ~ '.' ~ _src.schema ~ '.' ~ _id %}
                        {% set _fmt = (_src.meta or {}).get('si_table_format', 'iceberg') %}
                        {% do _results.update({_key: {
                            'database': _src.database,
                            'schema': _src.schema,
                            'identifier': _id,
                            'table_format': _fmt,
                            'label': _label
                        }}) %}
                    {% endif %}

                {#-- model / seed / snapshot node --#}
                {% elif _uid in graph.nodes %}
                    {% set _n = graph.nodes[_uid] %}
                    {% set _rtype = _n.resource_type %}
                    {% set _label = _n.name %}

                    {% if _rtype == 'model' %}
                        {% set _mat = _n.config.materialized %}
                        {% if _label in _ignore_set %}
                            {#-- explicitly ignored: drop it, do NOT descend into its upstreams --#}
                            {% do _ignore_set.update({_label: true}) %}
                        {% elif _mat in ('ephemeral', 'view') %}
                            {#-- transparent: descend into its upstream --#}
                            {% for _dep in (_n.depends_on.nodes or []) %}
                                {% if _dep not in _visited %}
                                    {% do _queue.append(_dep) %}
                                {% endif %}
                            {% endfor %}
                        {% else %}
                            {#-- physical table --#}
                            {% set _id = _n.alias or _n.name %}
                            {% set _key = _n.database ~ '.' ~ _n.schema ~ '.' ~ _id %}
                            {% set _fmt = (_n.config.meta or _n.meta or {}).get('si_table_format', 'iceberg') %}
                            {% do _results.update({_key: {
                                'database': _n.database,
                                'schema': _n.schema,
                                'identifier': _id,
                                'table_format': _fmt,
                                'label': _label
                            }}) %}
                        {% endif %}

                    {% elif _rtype in ('seed', 'snapshot') %}
                        {% if _label in _ignore_set %}
                            {% do _ignore_set.update({_label: true}) %}
                        {% else %}
                            {#-- physical table --#}
                            {% set _id = _n.alias or _n.name %}
                            {% set _key = _n.database ~ '.' ~ _n.schema ~ '.' ~ _id %}
                            {% set _fmt = (_n.config.meta or _n.meta or {}).get('si_table_format', 'iceberg') %}
                            {% do _results.update({_key: {
                                'database': _n.database,
                                'schema': _n.schema,
                                'identifier': _id,
                                'table_format': _fmt,
                                'label': _label
                            }}) %}
                        {% endif %}

                    {#-- other resource types: ignore --#}
                    {% endif %}
                {% endif %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {#-- warn about ignore entries that matched nothing (typo guard) --#}
    {% set _unmatched = [] %}
    {% for _ig, _hit in _ignore_set.items() %}
        {% if not _hit %}
            {% do _unmatched.append(_ig) %}
        {% endif %}
    {% endfor %}
    {% if _unmatched | length > 0 %}
        {% do exceptions.warn(
            "(smart_incremental) si_check_ignore: no source matched " ~ _unmatched
            ~ " for model '" ~ _node.name ~ "'. Check the dbt name (source: '<source_name>.<table>', model: '<name>')."
        ) %}
    {% endif %}

    {#-- flatten dict values to a list --#}
    {% set _out = [] %}
    {% for _v in _results.values() %}
        {% do _out.append(_v) %}
    {% endfor %}
    {{ return(_out) }}

{% endmacro %}
