#' Create data model from database constraints
#'
#' @description If there are any permament tables on a DB, a new [`dm`] object can be created that contains those tables,
#' along with their primary and foreign key constraints.
#'
#' Currently this only works with MSSQL and Postgres databases.
#'
#' The default database schema will be used; it is currently not possible to parametrize the funcion with a specific database schema.
#'
#' @param dest A `src`-object on a DB or a connection to a DB.
#' @param ...
#'   \lifecycle{experimental}
#'
#'   Additional parameters for the schema learning query.
#'   Currently supports `schema` (default: `"public"`)
#'   and `table_type` (default: `"BASE TABLE"`) for Postgres databases.
#'
#' @family DB interaction functions
#'
#' @return A [`dm`] object with the tables from the DB and the respective key relations.
#'
#' @noRd
#' @examples
#' if (FALSE) {
#'   src_sqlite <- dplyr::src_sqlite(":memory:", create = TRUE)
#'   iris_key <- mutate(iris, key = row_number())
#'
#'   # setting key constraints currently doesn't work on
#'   # SQLite but this would be the code to set the PK
#'   # constraint on the DB
#'   iris_dm <- copy_dm_to(
#'     src_sqlite,
#'     dm(iris = iris_key),
#'     set_key_constraints = TRUE
#'   )
#'
#'   # and this would be the code to learn
#'   # the `dm` from the SQLite DB
#'   iris_dm_learned <- dm_learn_from_db(src_sqlite)
#' }
dm_learn_from_db <- function(dest, ...) {
  # assuming that we will not try to learn from (globally) temporary tables, which do not appear in sys.table
  con <- con_from_src_or_con(dest)
  src <- src_from_src_or_con(dest)

  if (is.null(con)) {
    return()
  }

  sql <- db_learn_query(con, ...)
  if (is.null(sql)) {
    return()
  }

  overview <-
    dbGetQuery(con, sql) %>%
    as_tibble()
  if (nrow(overview) == 0) {
    return(NULL)
  } else {
    overview <- arrange(overview, table)
  }

  table_names <- overview %>%
    select(schema, table) %>%
    transmute(name = table, value = schema_if(schema, table)) %>%
    deframe()

  legacy_new_dm(
    tables = map(table_names, ~ tbl(con, dbplyr::ident_q(.x))),
    data_model = get_datamodel_from_overview(overview)
  )
}

schema_if <- function(schema, table) {
  if_else(is.na(schema), table, paste0(schema, ".", table))
}

db_learn_query <- function(dest, ...) {
  if (is_mssql(dest)) {
    return(mssql_learn_query())
  }
  if (is_postgres(dest)) {
    return(postgres_learn_query(dest, ...))
  }
}

mssql_learn_query <- function() { # taken directly from {datamodelr}
  "select
    NULL as [schema],
    tabs.name as [table],
    cols.name as [column],
    isnull(ind_col.column_id, 0) as [key],
    OBJECT_NAME (ref.referenced_object_id) AS ref,
    COL_NAME (ref.referenced_object_id, ref.referenced_column_id) AS ref_col,
    1 - cols.is_nullable as mandatory,
    types.name as [type],
    cols.max_length,
    cols.precision,
    cols.scale
  from
    sys.all_columns cols
    inner join sys.tables tabs on
      cols.object_id = tabs.object_id
    left outer join sys.foreign_key_columns ref on
      ref.parent_object_id = tabs.object_id
      and ref.parent_column_id = cols.column_id
    left outer join sys.indexes ind on
      ind.object_id = tabs.object_id
      and ind.is_primary_key = 1
    left outer join sys.index_columns ind_col on
      ind_col.object_id = ind.object_id
      and ind_col.index_id = ind.index_id
      and ind_col.column_id = cols.column_id
    left outer join sys.systypes [types] on
      types.xusertype = cols.system_type_id
  order by
    tabs.create_date,
    cols.column_id"
}

postgres_learn_query <- function(con, schema = "public", table_type = "BASE TABLE") {
  sprintf(
    "SELECT
    t.table_schema as schema,
    t.table_name as table,
    c.column_name as column,
    case when pk.column_name is null then 0 else 1 end as key,
    fk.ref,
    fk.ref_col,
    case c.is_nullable when 'YES' then 0 else 1 end as mandatory,
    c.data_type as type,
    c.ordinal_position as column_order

    from
    information_schema.columns c
    inner join information_schema.tables t on
    t.table_name = c.table_name
    and t.table_schema = c.table_schema
    and t.table_catalog = c.table_catalog

    left join  -- primary keys
    ( SELECT DISTINCT
      tc.constraint_name, tc.table_name, tc.table_schema, tc.table_catalog, kcu.column_name
      FROM
      information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu ON
      tc.constraint_name = kcu.constraint_name
      WHERE constraint_type = 'PRIMARY KEY'
    ) pk on
    pk.table_name = c.table_name
    and pk.column_name = c.column_name
    and pk.table_schema = c.table_schema
    and pk.table_catalog = c.table_catalog

    left join  -- foreign keys
    ( SELECT DISTINCT
      tc.constraint_name, kcu.table_name, kcu.table_schema, kcu.table_catalog, kcu.column_name,
      ccu.table_name as ref,
      ccu.column_name as ref_col
      FROM
      information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu ON
      tc.constraint_name = kcu.constraint_name
      JOIN information_schema.constraint_column_usage AS ccu ON
      ccu.constraint_name = tc.constraint_name
      WHERE tc.constraint_type = 'FOREIGN KEY'
    ) fk on
    fk.table_name = c.table_name
    and fk.table_schema = c.table_schema
    and fk.table_catalog = c.table_catalog
    and fk.column_name = c.column_name

    where
    c.table_schema = %s
    and t.table_type = %s",
    dbQuoteString(con, schema),
    dbQuoteString(con, table_type)
  )
}

# FIXME: only needed for `dm_learn_from_db()` <- needs to be implemented in a different manner
legacy_new_dm <- function(tables, data_model) {
  if (is_missing(tables) && is_missing(data_model)) {
    return(empty_dm())
  }
  if (!all_same_source(tables)) abort_not_same_src()
  stopifnot(is.data_model(data_model))

  columns <- as_tibble(data_model$columns)

  data_model_tables <- data_model$tables

  stopifnot(all(names(tables) %in% data_model_tables$table))
  stopifnot(all(data_model_tables$table %in% names(tables)))

  pks <- columns %>%
    select(column, table, key) %>%
    filter(key > 0) %>%
    select(-key)

  if (is.null(data_model$references) || nrow(data_model$references) == 0) {
    fks <- tibble(
      table = character(),
      column = character(),
      ref = character(),
      ref_col = character()
    )
  } else {
    fks <-
      data_model$references %>%
      select(table, column, ref, ref_col) %>%
      as_tibble()
  }

  # Legacy
  data <- unname(tables[data_model_tables$table])

  table <- data_model_tables$table
  segment <- data_model_tables$segment
  # would be logical NA otherwise, but if set, it is class `character`
  display <- as.character(data_model_tables$display)
  zoom <- new_zoom()
  col_tracker_zoom <- new_col_tracker_zoom()

  pks <-
    pks %>%
    # Legacy compatibility
    mutate(column = vctrs::vec_cast(column, list())) %>%
    nest_compat(pks = -table)

  pks <-
    tibble(
      table = setdiff(table, pks$table),
      pks = vctrs::list_of(new_pk())
    ) %>%
    vctrs::vec_rbind(pks)

  # Legacy compatibility
  fks$column <- as.list(fks$column)

  fks <-
    fks %>%
    select(-ref_col) %>%
    nest_compat(fks = -ref) %>%
    rename(table = ref)

  fks <-
    tibble(
      table = setdiff(table, fks$table),
      fks = vctrs::list_of(new_fk())
    ) %>%
    vctrs::vec_rbind(fks)

  # there are no filters at this stage
  filters <-
    tibble(
      table = table,
      filters = vctrs::list_of(new_filter())
    )

  def <-
    tibble(table, data, segment, display) %>%
    left_join(pks, by = "table") %>%
    left_join(fks, by = "table") %>%
    left_join(filters, by = "table") %>%
    left_join(zoom, by = "table") %>%
    left_join(col_tracker_zoom, by = "table")

  new_dm3(def)
}

nest_compat <- function(.data, ...) {
  # `...` has to be name-variable pair (see `?nest()`) of length 1
  quos <- enquos(...)
  stopifnot(length(quos) == 1)
  new_col <- names(quos)
  if (nrow(.data) == 0) {
    remove <- eval_select_indices(quo(c(...)), colnames(.data))
    keep <- setdiff(seq_along(.data), remove)

    nest <- vctrs::new_list_of(list(), ptype = .data %>% select(!!!remove))

    .data %>%
      select(!!!keep) %>%
      mutate(!!new_col := !!nest)
  } else {
    nest(.data, ...) %>%
      mutate_at(vars(new_col), vctrs::as_list_of)
  }
}
