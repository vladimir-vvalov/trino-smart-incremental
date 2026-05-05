# smart_incremental — план розробки (dbt-trino package)

## Огляд

`smart_incremental` — кастомна матеріалізація для dbt-trino.  
Мета: розширити стандартні стратегії `delete+insert` і `merge` новою механікою
фільтрації та порівняння, зберігши сумісність із `incremental` при перемиканні туди
і назад без зміни параметрів.

---

## Структура файлів

```
smart_incremental/
├── incremental/
│   ├── si_incremental.sql   # тільки код кастомної матеріалізації
│   ├── si_strategies.sql    # SQL-макроси стратегій (trino__si_get_*_sql)
│   └── si_validate.sql      # валідація та нормалізація параметрів конфігу
└── database/
    ├── si_check_relation.sql # перевірка існування об'єкту в БД
    ├── si_is_incremental.sql # is_incremental для si_incremental
    └── si_get_values.sql     # читання значень із БД у словники
```

---

## Параметри конфігурації

### Стандартні параметри dbt — сумісні, без змін

| Параметр                | Тип            | Опис                                                         |
|-------------------------|----------------|--------------------------------------------------------------|
| `unique_key`            | string / list  | Ключ JOIN для `merge`                                        |
| `incremental_predicates`| list           | Додаткові фільтри WHERE при інкрементальному оновленні       |
| `merge_update_columns`  | list           | Стовпці для оновлення при `merge`                            |
| `merge_exclude_columns` | list           | Стовпці, що виключаються з оновлення при `merge`             |
| `on_schema_change`      | string         | Поведінка при зміні схеми (`ignore` / `fail` / `append_new_columns` / `sync_all_columns`) |
| `on_table_exists`       | string         | Поведінка при full refresh (`rename` / `drop` / `replace`)  |

### Нові параметри si_incremental

Всі нові параметри мають префікс `si_` — для візуальної асоціації з пакетом і
відсутності конфліктів зі стандартними параметрами dbt.

| Параметр                          | Тип            | Дефолт  | Опис                                                                                                  |
|-----------------------------------|----------------|---------|-------------------------------------------------------------------------------------------------------|
| `si_tmp`                       | string         | `'view'`| Тип tmp-релейшна: `'view'` або `'table'`. Дефолт `'view'` відповідає логіці стандартного `get_incremental_tmp_relation_type` для `merge` / `append`. `'table'` потрібен для multi-statement стратегій або явного кешування |
| `si_key`                       | string / list  | `none`  | Поле(я) для фільтрації цільової таблиці у стратегії `delete+insert`. Семантично ≠ `unique_key` — це ключ зрізу або партиції, не PK |
| `si_mode`                      | string         | `none`  | Режим фільтрації: `'in'` / `'between'` / `'>'` / `'>='` / `'<'` / `'<='` / `none`                   |
| `si_min`                       | string / number| `none`  | Нижня межа діапазону для `si_mode` в режимах `'between'`, `'>'`, `'>='`. Якщо не задано — береться `MIN(si_key)` із tmp |
| `si_max`                       | string / number| `none`  | Верхня межа діапазону для `si_mode` в режимах `'between'`, `'<'`, `'<='`. Якщо не задано — береться `MAX(si_key)` із tmp |
| `si_compare`                   | bool           | `false` | Для `merge`: чи перевіряти зміну значень перед UPDATE. Якщо `true` — UPDATE виконується лише при розбіжності хоча б одного відстежуваного поля |
| `si_compare_columns`           | list           | `none`  | При `si_compare: true` — whitelist стовпців для порівняння. Взаємовиключає `si_exclude_compare_columns` |
| `si_exclude_compare_columns`   | list           | `none`  | При `si_compare: true` — стовпці, що виключаються з порівняння. Взаємовиключає `si_compare_columns` |
| `si_update_predicates`         | string / list  | `none`  | Для `merge`: додаткова умова в секції `WHEN MATCHED THEN UPDATE` (поза JOIN-умовою). Синтаксис аналогічний `incremental_predicates`. Не конфліктує при перемиканні на `incremental` — ігнорується |
| `si_null_key`                  | string         | `'warn'`| Поведінка при виявленні NULL серед значень `si_key` після читання з tmp (`si_mode='in'`): `'warn'` — виводити попередження і продовжити (NULL-рядки в target не видаляться), `'error'` — зупинити з помилкою компіляції, `'ignore'` — мовчки ігнорувати. Не впливає на інші режими `si_mode` |
| `si_in_rows_limit`             | int / none     | `100000` | Поріг кількості значень у `IN(...)` при `si_mode='in'`, після якого виводиться WARNING. `none` — відключає перевірку повністю. Задається на рівні моделі або через `vars` у `dbt_project.yml` |

### Сумісність при перемиканні матеріалізацій

- `smart_incremental` → `incremental`: нові параметри (`si_key`, `si_mode`,
  `si_min`, `si_max`, `si_compare`, `si_compare_columns`,
  `si_exclude_compare_columns`, `si_update_predicates`, `si_null_key`, `si_in_rows_limit`, `si_tmp`) не
  використовуються стандартним `incremental` і будуть проігноровані — конфліктів немає.
- `incremental` → `smart_incremental`: `unique_key`, `incremental_predicates`,
  `merge_update_columns`, `merge_exclude_columns` мають однакову семантику в обох
  матеріалізаціях і працюватимуть без змін.

---

## Стратегії

### `append`

Без змін: `INSERT INTO target SELECT * FROM tmp`.  
Нові параметри ігноруються. Дефолтна стратегія — поведінка стандартна.

---

### `delete+insert` — нова механіка видалення

**Проблема зі стандартною механікою:**  
`DELETE FROM target WHERE unique_key IN (SELECT unique_key FROM tmp)` — субквері в
`IN(...)` або `EXISTS(...)` може бути неефективним або непідтримуваним у Trino для
великих таблиць.

**Нова механіка:**

1. Зчитати значення із `tmp` через `si_get_filter_values`:
   - для `si_mode = 'in'`: DISTINCT значення(а) `si_key`
   - для інших режимів: MIN / MAX по першому полю `si_key` (якщо `si_min` /
     `si_max` не задані вручну — береться з tmp; якщо задані — використовується
     вручну задане значення як є, без запиту до tmp)
2. Сформувати `DELETE` з явним переліком значень (без субквері):
   - `si_mode = 'in'`:
     ```sql
     DELETE FROM target
     WHERE si_key IN ('v1', 'v2', 'v3', ...)
     ```
     При `si_key` як list — конкатенація полів через роздільник `'|'` в Trino:
     ```sql
     DELETE FROM target
     WHERE CAST(col1 AS VARCHAR) || '|' || CAST(col2 AS VARCHAR) IN ('v1|w1', 'v2|w2', ...)
     ```
     Та сама конкатенація застосовується до значень, прочитаних із tmp.
   - `si_mode = 'between'`:
     ```sql
     DELETE FROM target WHERE si_key BETWEEN <min> AND <max>
     ```
   - `si_mode = '>'` / `'>='`:
     ```sql
     DELETE FROM target WHERE si_key > <min>
     DELETE FROM target WHERE si_key >= <min>
     ```
   - `si_mode = '<'` / `'<='`:
     ```sql
     DELETE FROM target WHERE si_key < <max>
     DELETE FROM target WHERE si_key <= <max>
     ```
3. Після DELETE — стандартний `INSERT INTO target SELECT * FROM tmp`

**`si_min` / `si_max` — ручне задання меж:**

Дозволяє не читати tmp для отримання меж — корисно, коли межі відомі заздалегідь
(наприклад, задаються через `var()`). Якщо задано `si_min` і/або `si_max` —
запит до tmp для відповідної межі не виконується.

**WARNING при великому `IN(...)`:**

При `si_mode='in'` — перевіряти кількість значень після їх зчитування.
Якщо кількість перевищує `si_in_rows_limit` — виводити `log(warning_message)` перед
генерацією SQL. Автоматичного обрізання немає — результат був би некоректним.
Якщо `si_in_rows_limit: none` — перевірка не виконується взагалі.

**Обробка NULL у значеннях `si_key` (`si_mode='in'`):**

Після отримання словника значень перевіряти наявність NULL серед них.
Поведінка визначається параметром `si_null_key`:
- `'warn'` (default): виводити `log(warning_message)` і продовжити. NULL-рядки
  в target NЕ видаляться (бо `NULL IN (...)` → `NULL`, не `TRUE`). Поведінка
  задокументована, користувач відповідає за дані.
- `'error'`: зупинити з `exceptions.raise_compiler_error`.
- `'ignore'`: мовчки пропустити, без жодних повідомлень.

Примітка: при `si_key` як list NULL у будь-якому з полів → вся конкатенація
повертає NULL, рядок також не видалиться. Перевірка охоплює і цей випадок.

---

### `merge` — розширення

**Основа:** стандартний `get_merge_sql` із dbt-core із Trino-специфічною реалізацією.

**Розширення 1 — `si_update_predicates`:**

Додаткова умова до секції `WHEN MATCHED`. Передається як рядок або list рядків
(аналогічно `incremental_predicates`). При list — об'єднуються через `AND`:
```sql
WHEN MATCHED AND <si_update_predicates> THEN UPDATE SET ...
```

**Розширення 2 — `si_compare`:**

Якщо `true` — генерується умова порівняння значень: UPDATE виконується лише коли
хоча б одне відстежуване поле відрізняється:
```sql
WHEN MATCHED AND NOT (
    target.col1 IS NOT DISTINCT FROM source.col1
    AND target.col2 IS NOT DISTINCT FROM source.col2
    AND ...
) THEN UPDATE SET ...
```

Стовпці для порівняння визначаються так:
1. Спочатку формується підмножина UPDATE-стовпців з урахуванням
   `merge_update_columns` / `merge_exclude_columns` (аналогічно логіці генерації
   `SET` у `get_merge_sql`) — порівнюються лише ті стовпці, що реально оновлюються.
2. Після цього застосовується фільтр `si_compare_columns` (whitelist) або
   `si_exclude_compare_columns` (blacklist) поверх підмножини UPDATE-стовпців.
3. `si_compare_columns` і `si_exclude_compare_columns` взаємовиключають одне одного.

Якщо задано і `si_update_predicates`, і `si_compare` — умови поєднуються через `AND`:
```sql
WHEN MATCHED AND <si_update_predicates> AND NOT (
    target.col1 IS NOT DISTINCT FROM source.col1 AND ...
) THEN UPDATE SET ...
```

---

## Файли: деталі реалізації

### `incremental/si_incremental.sql`

Містить лише матеріалізацію `{% materialization smart_incremental, adapter='trino' %}`.

**Відмінності від стандартного `trino__incremental`:**

- `get_incremental_tmp_relation_type` переозначена з урахуванням `si_tmp`:
  - якщо `si_tmp` заданий явно → використовувати його значення
  - інакше → стандартна логіка (`view` для `merge`/`append`, `table` для `delete+insert`)
- Вибір макросу стратегії: спочатку шукати `trino__si_get_<strategy>_sql`,
  якщо не знайдено → fallback до `adapter.get_incremental_strategy_macro` (стандарт)
- Перед побудовою SQL: виклик `si_validate_config()`, що повертає нормалізований
  dict параметрів
- Нормалізований dict передається разом із `strategy_arg_dict` до макросу стратегії

---

### `incremental/si_strategies.sql`

**Макроси:**

```
trino__si_get_delete_insert_sql(arg_dict)
trino__si_get_merge_sql(arg_dict)
```

**`trino__si_get_delete_insert_sql`:**
1. Отримати значення через `si_get_filter_values(tmp_relation, si_key, si_mode, si_min, si_max)`
2. При `si_mode='in'` — перевірити наявність NULL серед значень, відреагувати згідно `si_null_key`
3. При `si_mode='in'` — перевірити кількість значень, вивести WARNING при перевищенні порогу
4. При `si_key` як list і `si_mode='in'` — конкатенація через `||'|'||` з кастом до VARCHAR
5. Сформувати DELETE SQL по отриманих значеннях (без субквері)
6. INSERT SQL — стандартний

**`trino__si_get_merge_sql`:**
1. Базується на структурі `get_merge_sql` із dbt-core
2. Якщо `si_compare: true` — будує підмножину UPDATE-стовпців, потім застосовує
   `si_compare_columns` / `si_exclude_compare_columns`, генерує `IS NOT DISTINCT FROM` умову
3. Якщо `si_update_predicates` задано — додає до `WHEN MATCHED`
4. `si_compare` і `si_update_predicates` поєднуються через `AND`

---

### `incremental/si_validate.sql`

**Макрос:**
```
si_validate_config() → dict
```

Повертає нормалізований dict усіх параметрів після валідації.

Нормалізація (string → list):
- `si_key`, `unique_key`, `si_compare_columns`, `si_exclude_compare_columns`,
  `si_update_predicates`, `incremental_predicates`, `merge_update_columns`, `merge_exclude_columns`

Нормалізація `si_min` / `si_max`: зберігаються як є (string або number) —
форматування у SQL-значення виконує `si_format_sql_value` при генерації DELETE.

**Валідація / помилки компіляції:**

| Умова                                                                                              | Дія                                                                              |
|----------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| `si_mode` не в допустимому списку                                                               | `exceptions.raise_compiler_error`: `invalid si_mode`                          |
| `si_mode` задано, але `si_key` відсутній                                                     | `exceptions.raise_compiler_error`: `si_key required when si_mode is set`   |
| Стратегія `delete+insert` і `si_mode is none`                                                   | `exceptions.raise_compiler_error`: `si_mode required for delete+insert`       |
| `si_compare_columns` і `si_exclude_compare_columns` задані одночасно                         | `exceptions.raise_compiler_error`: mutually exclusive                            |
| `si_compare: false` але `si_compare_columns` або `si_exclude_compare_columns` задані      | `log` warning, ігнорувати                                                        |
| `si_in_rows_limit` задано і не є цілим числом або < 1                                        | `exceptions.raise_compiler_error`: `invalid si_in_rows_limit`                 |
| `si_min` задано без `si_mode` у відповідному режимі (`between`, `>`, `>=`)                   | `log` warning                                                                    |
| `si_max` задано без `si_mode` у відповідному режимі (`between`, `<`, `<=`)                   | `log` warning                                                                    |
| `si_null_key` не в допустимому списку (`'warn'`, `'error'`, `'ignore'`)                         | `exceptions.raise_compiler_error`: `invalid si_null_key`                      |
| NULL серед значень `si_key` при `si_mode='in'` і `si_null_key='error'`                    | `exceptions.raise_compiler_error`: NULL values found in si_key                |
| NULL серед значень `si_key` при `si_mode='in'` і `si_null_key='warn'`                     | `log` warning, продовжити                                                        |

---

### `database/si_check_relation.sql`

**Макроси:**
```
si_check_relation(relation=this, use_cache=none) → bool
si_check_table(model_name=model.name, schema_name=model.schema, database_name=model.database, use_cache=none) → bool
```

`si_check_relation` — обгортка над `si_check_table`, передає поля з об'єкта relation.

Параметр `use_cache`:
- `true`  → тільки кеш (`adapter.get_relation`), без запиту до БД
- `false` → тільки БД (запит до `information_schema`)
- `none` (default) → спочатку кеш; якщо miss → запит до БД

`si_check_table` також виконує попередню перевірку існування каталогу через `system.metadata.catalogs` — але лише якщо `database_name != model.database` (для зовнішніх БД).

---

### `database/si_is_incremental.sql`

**Макрос:**
```
si_is_incremental() → bool
```

Аналог `is_incremental()` але з перевіркою `'si_incremental'`.

Причина: стандартний `is_incremental()` хардкодить `model.config.materialized == 'incremental'`
(перевірено в dbt-core source) — не підходить для кастомної матеріалізації.

Реалізація аналогічна до `is_incremental()`: використовує `adapter.get_relation`
для перевірки існування, а не `load_cached_relation` (щоб уникнути false-negative
у випадках, коли кеш ще не заповнений):

```jinja
{% macro si_is_incremental() %}
  {#-- do not run introspective queries in parsing #}
  {% if not execute %}
    {{ return(False) }}
  {% else %}
    {% set relation = adapter.get_relation(this.database, this.schema, this.table) %}
    {{ return(relation is not none
             and relation.type == 'table'
             and model.config.materialized == 'smart_incremental'
             and not should_full_refresh()) }}
  {% endif %}
{% endmacro %}
```

---

### `database/si_get_values.sql`

**Читання в словник:**
```
si_get_values(table=model.name, schema=model.schema, database=model.database,
              sql_query='', row_name_by='', is_quoting=none) → dict
```
Якщо `sql_query` не задано — будується `SELECT * FROM "db"."schema"."table"`.  
Якщо задано — використовується як є (без жодних замін).  
Запит обгортається в `SELECT * FROM (...) LIMIT N`.  
Повертає `{ row_id: { col_name: value, ... }, ... }`.  
`row_id` — значення стовпця `row_name_by` або loop index (0-based).  
Ліміт береться з `config.si_in_rows_limit` (default: 1 000 000).  
Якщо таблиця не існує — повертає `{}`.

**Читання значень для фільтра DELETE:**
```
si_get_filter_values(relation, si_key, si_mode, si_min=none, si_max=none) → dict
```
Повертає dict із ключами залежно від режиму:
- `si_mode = 'in'`:
  - `si_key` як рядок → DISTINCT значення з tmp:
    `{'values': ['v1', 'v2', ...], 'count': N}`
  - `si_key` як list → конкатенація через `||'|'||` з CAST до VARCHAR:
    `{'values': ['v1|w1', 'v2|w2', ...], 'count': N, 'composite': True}`
- `si_mode in ('between', '>', '>=', '<', '<=')`:
  - `si_min` заданий вручну → `{'min': si_min}`, не читати tmp
  - `si_max` заданий вручну → `{'max': si_max}`, не читати tmp
  - не задані → `{'min': MIN(first_key), 'max': MAX(first_key)}` із tmp

**Читання distinct рядків по списку стовпців:**
```
si_get_distinct_values(relation, columns) → list of dicts
```

---

## Взаємодія зі стандартними макросами dbt-core / dbt-trino

| Макрос                                  | Джерело    | Використання у si_incremental                         |
|-----------------------------------------|------------|----------------------------------------------------------|
| `create_table_as`                       | dbt-core   | без змін                                                 |
| `create_view_as`                        | dbt-core   | без змін                                                 |
| `process_schema_changes`                | dbt-core   | без змін                                                 |
| `adapter.expand_target_column_types`    | dbt-core   | без змін                                                 |
| `make_temp_relation`                    | dbt-core   | без змін                                                 |
| `make_intermediate_relation`            | dbt-core   | без змін                                                 |
| `make_backup_relation`                  | dbt-core   | без змін                                                 |
| `drop_relation_if_exists`               | dbt-core   | без змін                                                 |
| `apply_grants`, `persist_docs`          | dbt-core   | без змін                                                 |
| `get_merge_sql`                         | dbt-core   | базова структура для `trino__si_get_merge_sql`        |
| `incremental_validate_on_schema_change` | dbt-core   | без змін                                                 |
| `load_cached_relation`                  | dbt-core   | використовується в `si_check_relation`                |
| `run_query`                             | dbt-core   | через `si_run_query`                                  |
| `should_full_refresh`                   | dbt-core   | без змін                                                 |

**Переозначені / замінені:**

| Стандартний макрос                    | Заміна у si_incremental                          | Причина                                         |
|---------------------------------------|-----------------------------------------------------|-------------------------------------------------|
| `get_incremental_tmp_relation_type`   | Вбудована логіка у матеріалізацію з `si_tmp`     | Новий параметр                                  |
| `trino__get_delete_insert_merge_sql`  | `trino__si_get_delete_insert_sql`                | Нова механіка видалення без субквері            |
| `trino__get_merge_sql`                | `trino__si_get_merge_sql`                        | `si_compare` + `si_update_predicates`     |

---

## Вирішені питання

- [x] **Великий `IN(...)`**: не обрізати (некоректний результат). Виводити `log` WARNING
  при перевищенні порогу. Поріг — до визначення під час реалізації (орієнтир: 10 000).
- [x] **`si_key` як list + `si_mode='in'`**: конкатенація через роздільник `'|'`
  з CAST до VARCHAR у Trino: `CAST(col1 AS VARCHAR) || '|' || CAST(col2 AS VARCHAR)`.
  Та сама конкатенація застосовується до даних, прочитаних із tmp. Роздільник `'|'`
  фіксований — треба документувати обмеження (значення полів не повинні містити `'|'`).
- [x] **`si_compare` + UPDATE підмножина**: порівнювати лише стовпці, що входять
  у підмножину UPDATE (з урахуванням `merge_update_columns` / `merge_exclude_columns`).
  Потім застосовувати `si_compare_columns` / `si_exclude_compare_columns` поверх.
- [x] **`si_update_predicates`**: string або list of strings — аналогічно
  `incremental_predicates` у dbt-core. При list — об'єднання через `AND`.
- [x] **Namespace**: всі макроси пакету мають префікс `si_`. Залишки `tbmacro_*`
  замінити на `si_*` при рефакторингу файлів.
- [x] **`si_is_incremental()`**: потрібен. Стандартний `is_incremental()` хардкодить
  `model.config.materialized == 'incremental'` — не підходить для `'si_incremental'`.

---

## TODO (ще не вирішено)

- [ ] Визначити конкретний поріг для WARNING при великому `IN(...)` (орієнтир: 10 000)
- [ ] Уточнити: чи роздільник `'|'` фіксований, чи задається параметром `si_separator`
  (на випадок, якщо дані самі містять `'|'`)
- [ ] При конкатенації для `si_mode='in'` — чи потрібен CAST і у цільовій таблиці
  в умові WHERE, або достатньо CAST лише при читанні із tmp
- [ ] Перевірити поведінку `IS NOT DISTINCT FROM` у Trino для NULL-значень
  (має працювати коректно, але потрібно верифікувати)
