#' Check if column(s) can be used as keys
#'
#' @description `check_key()` accepts a data frame and, optionally, columns.
#' It throws an error
#' if the specified columns are NOT a unique key of the data frame.
#' If the columns given in the ellipsis ARE a key, the data frame itself is returned silently, so that it can be used for piping.
#'
#' @param .data The data frame whose columns should be tested for key properties.
#' @param ... The names of the columns to be checked.
#'
#'   One or more unquoted expressions separated by commas.
#'   Variable names can be treated as if they were positions, so you
#'   can use expressions like x:y to select ranges of variables.
#'
#'   The arguments in ... are automatically quoted and evaluated in a context where column names represent column positions.
#'   They also support
#'   unquoting and splicing.
#'   See vignette("programming") for an introduction to these concepts.
#'
#'   See select helpers for more details and examples about tidyselect helpers such as starts_with(), everything(), ...
#'
#' @return Returns `.data`, invisibly, if the check is passed.
#'   Otherwise an error is thrown and the reason for it is explained.
#'
#' @export
#' @examples
#' data <- tibble::tibble(a = c(1, 2, 1), b = c(1, 4, 1), c = c(5, 6, 7))
#' # this is failing:
#' try(check_key(data, a, b))
#'
#' # this is passing:
#' check_key(data, a, c)
check_key <- function(.data, ...) {
  data_q <- enquo(.data)
  .data <- eval_tidy(data_q)

  # No special handling for no columns
  cols_chosen <- eval_select_indices(quo(c(...)), colnames(.data))
  orig_names <- names(cols_chosen)
  names(cols_chosen) <- glue("...{seq_along(cols_chosen)}")

  duplicate_rows <-
    .data %>%
    select(!!!cols_chosen) %>%
    count(!!!syms(names(cols_chosen))) %>%
    select(n) %>%
    filter(n > 1) %>%
    head(1) %>%
    collect()

  if (nrow(duplicate_rows) != 0) {
    abort_not_unique_key(as_label(data_q), orig_names)
  }

  invisible(.data)
}

# an internal function to check if a column is a unique key of a table
is_unique_key <- function(.data, column) {
  col_expr <- ensym(column)
  col_name <- as_name(col_expr)

  duplicate_rows <-
    .data %>%
    count(value = !!col_expr) %>%
    filter(n != 1) %>%
    arrange(value) %>%
    utils::head(MAX_COMMAS + 1) %>%
    collect() %>%
    {
      # https://github.com/tidyverse/tidyr/issues/734
      tibble(data = list(.))
    } %>%
    mutate(unique = map_lgl(data, ~ nrow(.) == 0))

  duplicate_rows
}

#' Check column values for set equality
#'
#' @description `check_set_equality()` is a wrapper of `check_subset()`.
#' It tests if one value set is a subset of another and vice versa, i.e., if both sets are the same.
#' If not, it throws an error.
#'
#' @param t1 The data frame that contains column `c1`.
#' @param c1 The column of `t1` that should only contain values that are also present in column `c2` of data frame `t2`.
#' @param t2 The data frame that contains column `c2`.
#' @param c2 The column of `t2` that should only contain values that are also present in column `c1` of data frame `t1`.
#'
#' @return Returns `t1`, invisibly, if the check is passed.
#'   Otherwise an error is thrown and the reason for it is explained.
#'
#' @export
#' @examples
#' data_1 <- tibble::tibble(a = c(1, 2, 1), b = c(1, 4, 1), c = c(5, 6, 7))
#' data_2 <- tibble::tibble(a = c(1, 2, 3), b = c(4, 5, 6), c = c(7, 8, 9))
#' # this is failing:
#' try(check_set_equality(data_1, a, data_2, a))
#'
#' data_3 <- tibble::tibble(a = c(2, 1, 2), b = c(4, 5, 6), c = c(7, 8, 9))
#' # this is passing:
#' check_set_equality(data_1, a, data_3, a)
check_set_equality <- function(t1, c1, t2, c2) {
  t1q <- enquo(t1)
  t2q <- enquo(t2)

  c1q <- ensym(c1)
  c2q <- ensym(c2)

  catcher_1 <- tryCatch(
    {
      check_subset(!!t1q, !!c1q, !!t2q, !!c2q)
      NULL
    },
    error = identity
  )

  catcher_2 <- tryCatch(
    {
      check_subset(!!t2q, !!c2q, !!t1q, !!c1q)
      NULL
    },
    error = identity
  )

  catchers <- compact(list(catcher_1, catcher_2))

  if (length(catchers) > 0) {
    abort_sets_not_equal(map_chr(catchers, conditionMessage))
  }

  invisible(eval_tidy(t1q))
}

#' Check column values for subset
#'
#' @description `check_subset()` tests if the values of the chosen column `c1` of data frame `t1` are a subset of the values
#' of column `c2` of data frame `t2`.
#'
#' @param t1 The data frame that contains column `c1`.
#' @param c1 The column of `t1` that should only contain the values that are also present in column `c2` of data frame `t2`.
#' @param t2 The data frame that contains column `c2`.
#' @param c2 The column of the second data frame that has to contain all values of `c1` to avoid an error.
#'
#' @return Returns `t1`, invisibly, if the check is passed.
#'   Otherwise an error is thrown and the reason for it is explained.
#'
#' @export
#' @examples
#' data_1 <- tibble::tibble(a = c(1, 2, 1), b = c(1, 4, 1), c = c(5, 6, 7))
#' data_2 <- tibble::tibble(a = c(1, 2, 3), b = c(4, 5, 6), c = c(7, 8, 9))
#' # this is passing:
#' check_subset(data_1, a, data_2, a)
#'
#' # this is failing:
#' try(check_subset(data_2, a, data_1, a))
check_subset <- function(t1, c1, t2, c2) {
  t1q <- enquo(t1)
  t2q <- enquo(t2)

  c1q <- ensym(c1)
  c2q <- ensym(c2)

  if (is_subset(eval_tidy(t1q), !!c1q, eval_tidy(t2q), !!c2q)) {
    return(invisible(eval_tidy(t1q)))
  }

  # Hier kann nicht t1 direkt verwendet werden, da das für den Aufruf
  # check_subset(!!t1q, !!c1q, !!t2q, !!c2q) der Auswertung des Ausdrucks !!t1q
  # entsprechen würde; dies ist nicht erlaubt.
  # Siehe eval-bang.R für ein Minimalbeispiel.
  v1 <- pull(eval_tidy(t1q), !!ensym(c1q))
  v2 <- pull(eval_tidy(t2q), !!ensym(c2q))

  setdiff_v1_v2 <- setdiff(v1, v2)
  print(filter(eval_tidy(t1q), !!c1q %in% setdiff_v1_v2))

  abort_not_subset_of(as_name(t1q), as_name(c1q), as_name(t2q), as_name(c2q))
}

# similar to `check_subset()`, but evaluates to a boolean
is_subset <- function(t1, c1, t2, c2) {
  t1q <- enquo(t1)
  t2q <- enquo(t2)

  c1q <- ensym(c1)
  c2q <- ensym(c2)

  # Hier kann nicht t1 direkt verwendet werden, da das für den Aufruf
  # check_subset(!!t1q, !!c1q, !!t2q, !!c2q) der Auswertung des Ausdrucks !!t1q
  # entsprechen würde; dies ist nicht erlaubt.
  # Siehe eval-bang.R für ein Minimalbeispiel.
  v1 <- pull(eval_tidy(t1q), !!ensym(c1q))
  v2 <- pull(eval_tidy(t2q), !!ensym(c2q))

  if (!all(v1 %in% v2)) FALSE else TRUE
}

check_pk_constraints <- function(dm) {
  pks <- dm_get_all_pks_impl(dm)
  if (nrow(pks) == 0) {
    return(tibble(
      table = character(0),
      kind = character(0),
      column = character(0),
      ref_table = NA_character_,
      is_key = logical(0),
      problem = character(0)
    ))
  }
  table_names <- pull(pks, table)
  tbls <- map(set_names(table_names), ~ tbl(dm, .)) %>%
    map2(syms(pks$pk_col), ~ select(.x, !!.y))
  tbl_is_pk <- map_dfr(tbls, enum_pk_candidates_impl) %>%
    mutate(table = table_names) %>%
    rename(is_key = candidate, problem = why)
  tibble(
    table = table_names,
    kind = "PK",
    column = pks$pk_col,
    ref_table = NA_character_
  ) %>%
    left_join(tbl_is_pk, by = c("table", "column"))
}

check_fk_constraints <- function(dm) {
  fks <- left_join(dm_get_all_fks_impl(dm), dm_get_all_pks_impl(dm), by = c("parent_table" = "table"))
  pts <- pull(fks, parent_table) %>% map(tbl, src = dm)
  cts <- pull(fks, child_table) %>% map(tbl, src = dm)
  fks_tibble <- mutate(fks, t1 = cts, t2 = pts) %>%
    select(t1, t1_name = child_table, colname = child_fk_cols, t2, t2_name = parent_table, pk = pk_col)
  mutate(
    fks_tibble,
    problem = pmap_chr(fks_tibble, check_fk),
    is_key = if_else(problem == "", TRUE, FALSE),
    kind = "FK"
  ) %>%
    select(table = t1_name, kind, column = colname, ref_table = t2_name, is_key, problem)
}

new_tracked_cols <- function(dm, selected) {
  tracked_cols <- get_tracked_cols(dm)
  old_tracked_names <- names(tracked_cols)
  # the new tracked keys need to be the remaining original column names
  # and their name needs to be the newest one (tidyselect-syntax)
  # `intersect(selected, old_tracked_names)` is empty, return `NULL`

  selected_match <- selected[selected %in% old_tracked_names]
  set_names(
    tracked_cols[selected_match],
    names(selected_match)
  )
}
