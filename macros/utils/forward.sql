{#--
  si_forward(model_name, is_same_tag=true)

  Like ref(), but resolves a downstream (child) model instead of an upstream one.
  Useful when a model needs to reference the table that will be populated by its
  calling child (e.g. reading existing rows before an overwrite).

  Parameters:
    model_name  – name of the downstream model to resolve
    is_same_tag – true (default): BFS searches only within nodes that share
                  at least one tag with the target model (faster).
                  false: BFS searches across all model nodes.

  Errors if:
    - model_name is not found as a downstream model of the current model
    - the target model is ephemeral or view

  Returns: Relation → renders as "database"."schema"."table" in compiled SQL
           none     → if the physical table does not yet exist in the DB
--#}
{% macro forward(model_name, is_same_tag=true) %}

    {#-- During parsing the graph is not fully populated — return a placeholder --#}
    {% if not execute %}
        {{ return(api.Relation.create(
            database=model.database,
            schema=model.schema,
            identifier=model_name
        )) }}
    {% endif %}

    {#-- Find any downstream (transitive) model with the given name.
         Pass 1: find candidate + its tags.
         Pass 2: build tagged family (nodes sharing ≥1 tag) → limited BFS universe.
         Pass 3: BFS upward from candidate within tagged family.
         current_uid is always reachable even if it shares no tags. --#}
    {% set current_uid = 'model.' ~ model.package_name ~ '.' ~ model.name %}
    {% set ns = namespace(target_uid=none, candidate_uid=none, candidate_tags=[]) %}

    {#-- Normalize is_same_tag: only literal true/false accepted --#}
    {% if is_same_tag is sameas true %}
        {% set _use_tags = true %}
    {% elif is_same_tag is sameas false %}
        {% set _use_tags = false %}
    {% else %}
        {{ exceptions.raise_compiler_error(
            "si_forward('" ~ model_name ~ "'): is_same_tag must be true or false, got: "
            ~ is_same_tag | string
        ) }}
    {% endif %}

    {#-- Pass 1: find candidate node.
         Fast path: O(1) dict lookup assuming the model lives in the current package.
         Fallback:  scan graph.nodes (with early-skip guard) — covers cross-package case. --#}
    {% set _fast_uid = 'model.' ~ model.package_name ~ '.' ~ model_name %}
    {% if _fast_uid in graph.nodes
          and graph.nodes[_fast_uid].resource_type == 'model' %}
        {% set ns.candidate_uid = _fast_uid %}
        {% set ns.candidate_tags = graph.nodes[_fast_uid].config.tags or [] %}
    {% else %}
        {% for uid, node in graph.nodes.items() %}
            {% if ns.candidate_uid is none
                  and node.resource_type == 'model'
                  and uid.split('.')[-1] == model_name %}
                {% set ns.candidate_uid = uid %}
                {% set ns.candidate_tags = node.config.tags or [] %}
            {% endif %}
        {% endfor %}
    {% endif %}

    {#-- Pass 2: tagged family (O(1) `in` checks via dicts used as sets) --#}
    {% set tagged_uids = {} %}
    {% if _use_tags and ns.candidate_tags | length > 0 %}
        {#-- candidate tags as a set for O(1) membership check --#}
        {% set _cand_tag_set = {} %}
        {% for t in ns.candidate_tags %}
            {% do _cand_tag_set.update({t: true}) %}
        {% endfor %}
        {#-- restrict to nodes sharing ≥1 tag with the candidate --#}
        {% for uid, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {% set _shared = namespace(found=false) %}
                {% for tag in (node.config.tags or []) %}
                    {% if not _shared.found and tag in _cand_tag_set %}
                        {% set _shared.found = true %}
                    {% endif %}
                {% endfor %}
                {% if _shared.found %}
                    {% do tagged_uids.update({uid: true}) %}
                {% endif %}
            {% endif %}
        {% endfor %}
    {% else %}
        {#-- is_same_tag=false or no tags: use all model nodes --#}
        {% for uid, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {% do tagged_uids.update({uid: true}) %}
            {% endif %}
        {% endfor %}
    {% endif %}

    {#-- Pass 3: BFS upward from candidate; always allow current_uid into queue.
         visited used as set (dict) for O(1) lookups. --#}
    {% if ns.candidate_uid is not none %}
        {% set queue = [] %}
        {% for dep in graph.nodes[ns.candidate_uid].depends_on.nodes %}
            {% if dep in tagged_uids or dep == current_uid %}
                {% do queue.append(dep) %}
            {% endif %}
        {% endfor %}

        {% set visited = {ns.candidate_uid: true} %}
        {% set found = namespace(val=false) %}

        {% for _ in range(tagged_uids | length) %}
            {% if not found.val and queue | length > 0 %}
                {% set next_uid = queue.pop(0) %}
                {% if next_uid == current_uid %}
                    {% set found.val = true %}
                {% elif next_uid not in visited %}
                    {% do visited.update({next_uid: true}) %}
                    {% for dep in graph.nodes[next_uid].depends_on.nodes %}
                        {% if dep not in visited and (dep in tagged_uids or dep == current_uid) %}
                            {% do queue.append(dep) %}
                        {% endif %}
                    {% endfor %}
                {% endif %}
            {% endif %}
        {% endfor %}

        {% if found.val %}
            {% set ns.target_uid = ns.candidate_uid %}
        {% endif %}
    {% endif %}

    {% if ns.target_uid is none %}
        {{ exceptions.raise_compiler_error(
            "si_forward('" ~ model_name ~ "'): no downstream model with this name "
            ~ "found for '" ~ model.name ~ "'."
        ) }}
    {% endif %}

    {#-- Load node definition --#}
    {% set node = graph.nodes[ns.target_uid] %}

    {#-- Disallow ephemeral and view materializations --#}
    {% set mat = node.config.materialized %}
    {% if mat in ('ephemeral', 'view') %}
        {{ exceptions.raise_compiler_error(
            "si_forward('" ~ model_name ~ "'): materialization '" ~ mat ~ "' is not allowed. "
            ~ "Only table or incremental models can be referenced via si_forward()."
        ) }}
    {% endif %}

    {#-- Check that the physical table actually exists; return none if not --#}
    {% if not smart_incremental.check_table(
            model_name = node.alias,
            schema_name = node.schema,
            database_name = node.database
    ) and not should_full_refresh() %}
        {{ return(none) }}
    {% endif %}

    {#-- Build and return the resolved relation --#}
    {{ return(api.Relation.create(
        database=node.database,
        schema=node.schema,
        identifier=node.alias
    )) }}

{% endmacro %}
