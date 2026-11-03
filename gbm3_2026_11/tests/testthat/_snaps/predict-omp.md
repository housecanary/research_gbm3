# invalid arguments and columns produce concise diagnostics

    Code
      omp_test_errors(list(missing_model = function() {
        predict_omp(newdata = data, n.trees = 1L, n_threads = 2L)
      }, missing_newdata = function() predict_omp(model, n.trees = 1L, n_threads = 2L),
      missing_trees = function() predict_omp(model, data, n_threads = 2L),
      missing_threads = function() predict_omp(model, data, 1L), matrix = function()
        predict_omp(model, as.matrix(data), 1L, 2L), missing_column = function()
        predict_omp(model, data.frame(y = 1:2), 1L, 2L), duplicate_column = function()
        {
          predict_omp(model, setNames(data.frame(1:2, 3:4), c("x", "x")), 1L, 2L)
        }, numeric_character = function() predict_omp(model, data.frame(x = "1"), 1L,
      2L), numeric_factor = function() {
        predict_omp(model, data.frame(x = factor("a")), 1L, 2L)
      }, numeric_logical = function() predict_omp(model, data.frame(x = TRUE), 1L, 2L),
      numeric_object = function() predict_omp(model, data.frame(x = Sys.Date()), 1L,
      2L), numeric_matrix = function() {
        predict_omp(model, data.frame(x = I(matrix(1, 2, 1))), 1L, 2L)
      }, categorical_numeric = function() predict_omp(omp_test_model(TRUE), data, 1L,
      2L)))
    Output
      missing_model: argument "model" is missing, with no default
      missing_newdata: argument "newdata" is missing, with no default
      missing_trees: argument "n.trees" is missing, with no default
      missing_threads: argument "n_threads" is missing, with no default
      matrix: newdata must be a data.frame with each trained variable
      missing_column: newdata must be a data.frame with each trained variable
      duplicate_column: newdata must be a data.frame with each trained variable
      numeric_character: Numeric variable must be an ordinary numeric vector: x
      numeric_factor: Numeric variable must be an ordinary numeric vector: x
      numeric_logical: Numeric variable must be an ordinary numeric vector: x
      numeric_object: Numeric variable must be an ordinary numeric vector: x
      numeric_matrix: Numeric variable must be an ordinary numeric vector: x
      categorical_numeric: Categorical variable must be factor/character: x

---

    Code
      omp_test_errors(cases)
    Output
      n.trees_null: n.trees must be one integer >= 0
      n.trees_empty: n.trees must be one integer >= 0
      n.trees_vector: n.trees must be one integer >= 0
      n.trees_na: n.trees must be one integer >= 0
      n.trees_nan: n.trees must be one integer >= 0
      n.trees_infinite: n.trees must be one integer >= 0
      n.trees_negative: n.trees must be one integer >= 0
      n.trees_fractional: n.trees must be one integer >= 0
      n.trees_character: n.trees must be one integer >= 0
      n.trees_logical: n.trees must be one integer >= 0
      n.trees_overflow: n.trees must be one integer >= 0
      n_threads_null: n_threads must be one integer >= 1
      n_threads_empty: n_threads must be one integer >= 1
      n_threads_vector: n_threads must be one integer >= 1
      n_threads_na: n_threads must be one integer >= 1
      n_threads_nan: n_threads must be one integer >= 1
      n_threads_infinite: n_threads must be one integer >= 1
      n_threads_negative: n_threads must be one integer >= 1
      n_threads_fractional: n_threads must be one integer >= 1
      n_threads_character: n_threads must be one integer >= 1
      n_threads_logical: n_threads must be one integer >= 1
      n_threads_overflow: n_threads must be one integer >= 1
      n_threads_zero: n_threads must be one integer >= 1

---

    Code
      predict_omp(model, data, 2L, 2L)
    Condition
      Error:
      ! n.trees exceeds the fitted tree count

# unsupported models, offsets and formulas are rejected

    Code
      omp_test_errors(list(wrong_class = function() predict_omp(unclass(model), data,
      1L, 2L), distribution = function() check("distribution", list(name = "Gaussian")),
      multiclass = function() check("num.classes", 2), init_missing = function()
        check("initF", NA_real_), init_infinite = function() check("initF", Inf),
      init_vector = function() check("initF", c(1, 2)), init_character = function()
        check("initF", "1"), offset_terms = function() check("Terms", terms(y ~ x +
        offset(x))), offset_call = function() check("call", quote(gbmt(offset = 0))),
      offset_model = function() check("model", list(offset = 0)),
      offset_explicit_zero = function() check("offset", 0), offset_retained = function()
        check("gbm_data_obj", list(offset = c(0, 1))), offset_retained_na = function()
        check("gbm_data_obj", list(offset = NA_real_)), transform = function() check(
        "Terms", terms(y ~ log(x))), interaction = function() check("Terms", terms(y ~
        x:z)), trees = function() check("trees", NULL), tree_count = function() check(
        "params", list(num_trees = 0L)), splits = function() check("c.splits", NULL)))
    Output
      wrong_class: Only gbm3 GBMFit Laplace regression models are supported
      distribution: Only gbm3 GBMFit Laplace regression models are supported
      multiclass: Multiclass models are unsupported
      init_missing: Expected a finite scalar regression initF
      init_infinite: Expected a finite scalar regression initF
      init_vector: Expected a finite scalar regression initF
      init_character: Expected a finite scalar regression initF
      offset_terms: Offsets are unsupported
      offset_call: Offsets are unsupported
      offset_model: Offsets are unsupported
      offset_explicit_zero: Offsets are unsupported
      offset_retained: Offsets are unsupported
      offset_retained_na: Offsets are unsupported
      transform: Formula transforms/interactions are unsupported
      interaction: Formula transforms/interactions are unsupported
      trees: n.trees exceeds the fitted tree count
      tree_count: n.trees exceeds the fitted tree count
      splits: Expected raw model$c.splits

# invalid variable metadata is rejected

    Code
      omp_test_errors(list(names_missing = function() check("var_names",
        NA_character_), names_empty = function() check("var_names", character()),
      names_duplicate = function() check("var_names", c("x", "x")), types_missing = function()
        check("var_type", NA_integer_), types_negative = function() check("var_type",
        -1L), types_fractional = function() check("var_type", 0.5), types_infinite = function()
        check("var_type", Inf), levels_not_list = function() check("var_levels", "a"),
      levels_length = function() check("var_levels", list()), trained_level_count = function()
        check("var_levels", list("a"), TRUE), trained_level_missing = function() {
        check("var_levels", list(c(letters[1:4], NA_character_)), TRUE)
      }, trained_level_duplicate = function() check("var_levels", list(rep("a", 5)),
      TRUE)))
    Output
      names_missing: Invalid model$variables metadata
      names_empty: Invalid model$variables metadata
      names_duplicate: Invalid model$variables metadata
      types_missing: Invalid model$variables metadata
      types_negative: Invalid model$variables metadata
      types_fractional: Invalid model$variables metadata
      types_infinite: Invalid model$variables metadata
      levels_not_list: Invalid model$variables metadata
      levels_length: Invalid model$variables metadata
      trained_level_count: Invalid trained factor levels
      trained_level_missing: Invalid trained factor levels
      trained_level_duplicate: Invalid trained factor levels

# malformed raw trees and cycles are rejected before traversal

    Code
      omp_test_errors(list(raw_list = function() check(tree = 1:8), field_count = function()
        check(tree = tree[-8]), empty_nodes = function() check(tree = lapply(tree,
        function(x) x[FALSE])), integer_field = function() check(1L, as.double(tree[[
        1]])), double_field = function() check(2L, as.integer(tree[[2]])),
      matrix_field = function() check(2L, matrix(tree[[2]], 4, 1)), field_lengths = function()
        check(8L, 0), variable_index = function() check(1L, c(1L, -1L, -1L, -1L)),
      variable_na = function() check(1L, c(NA_integer_, -1L, -1L, -1L)),
      child_negative = function() check(3L, c(-1L, -1L, -1L, -1L)),
      child_out_of_range = function() check(4L, c(4L, -1L, -1L, -1L)), child_missing = function()
        check(5L, c(NA_integer_, -1L, -1L, -1L)), split_index = function() check(2L,
        c(1, -2, 3, 7), categorical = TRUE), split_fractional = function() check(2L,
        c(0.5, -2, 3, 7), categorical = TRUE), split_nonfinite = function() check(2L,
        c(Inf, -2, 3, 7), categorical = TRUE), split_length = function() check(
        categorical = TRUE, splits = list(c(-1L, 1L))), split_type = function() check(
        categorical = TRUE, splits = list(rep(0, 5))), cycle = function() check(tree = cycle),
      disconnected_cycle = function() check(tree = disconnected)))
    Output
      raw_list: Each selected tree must be a raw list of eight vectors
      field_count: Each selected tree must be a raw list of eight vectors
      empty_nodes: Each selected tree must have 1..INT_MAX nodes
      integer_field: splitvar must be an integer vector
      double_field: splitcodepred must be a double vector
      matrix_field: splitcodepred must be a double vector
      field_lengths: All eight tree fields must have equal lengths
      variable_index: Invalid split-variable index
      variable_na: Invalid split-variable index
      child_negative: Invalid internal child index: child=-1 is unsupported
      child_out_of_range: Invalid internal child index: child=-1 is unsupported
      child_missing: Invalid internal child index: child=-1 is unsupported
      split_index: Invalid zero-based c.split index
      split_fractional: Invalid zero-based c.split index
      split_nonfinite: Invalid zero-based c.split index
      split_length: c.split length disagrees with var_type category count
      split_type: c.split element must be an integer vector
      cycle: Cycle detected in tree
      disconnected_cycle: Cycle detected in tree

