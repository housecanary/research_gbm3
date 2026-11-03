.initialize_gbm_predictor <- function() {
  fail <- function(...) stop(..., call. = FALSE)
  if (identical(Sys.info()[["sysname"]], "Darwin")) {
    # Check before the first OpenMP call: LLVM may abort rather than error.
    registration <- Sys.getenv(paste0("__KMP_REGISTERED_LIB_", Sys.getpid()))
    if (grepl("libomp\\.a", registration)) {
      fail(
        "A static LLVM OpenMP runtime is already active in this R process. ",
        "Load gbm3 in a fresh R process without that runtime; ",
        "initializing another OpenMP runtime can abort R."
      )
    }
    dlls <- getLoadedDLLs()
    if ("xgboost" %in% names(dlls)) {
      dependencies <- tryCatch(
        suppressWarnings(system2(
          "/usr/bin/otool",
          c("-L", shQuote(dlls[["xgboost"]][["path"]])),
          stdout = TRUE,
          stderr = TRUE
        )),
        error = function(e) character()
      )
      if (
        !is.null(attr(dependencies, "status")) ||
          !any(grepl("libomp\\.dylib|libgomp", dependencies))
      ) {
        fail(
          "Loaded XGBoost may embed static OpenMP. Load gbm3 in a ",
          "separate R process without XGBoost; initializing another ",
          "runtime can abort R. Shared runtimes do not guarantee ",
          "coexistence safety."
        )
      }
    }
  }
  actual <- tryCatch(
    .Call("gbm_omp_team_size", 2L, PACKAGE = "gbm3"),
    error = function(e) {
      fail("gbm3 OpenMP initialization failed: ", conditionMessage(e))
    }
  )
  if (!identical(actual, 2L)) {
    fail(
      "gbm3 OpenMP initialization failed: requested 2 threads, got ",
      actual,
      ". Check OpenMP runtime/thread limits and restart R."
    )
  }
  invisible(actual)
}

#' Predict Laplace regression with OpenMP
#'
#' Predict from a prefix of the raw trees in a gbm3 Laplace regression fit,
#' parallelizing independent rows with OpenMP. The package checks that a
#' two-thread OpenMP team can be created when its namespace loads.
#'
#' @param model A gbm3 \code{GBMFit} Laplace regression model with one class,
#'   a finite scalar \code{initF}, valid trained-variable metadata, and raw
#'   \code{trees} and \code{c.splits} components.
#' @param newdata A data frame containing each trained variable exactly once.
#'   Extra columns are ignored. Numeric variables must be ordinary integer or
#'   double vectors; categorical variables must be factors or character vectors.
#' @param n.trees One integer-valued number from zero through the fitted tree
#'   count. Zero returns \code{model$initF} for every row.
#' @param n_threads One positive integer-valued thread count. The prediction
#'   team uses at most the number of rows (one thread for zero rows). An error
#'   is raised if the actual prediction team has fewer threads than requested
#'   after this cap. This does not change the global OpenMP thread setting.
#'
#' @details
#' Predictions sum already-shrunken terminal values in native tree order,
#' starting at \code{initF}; no additional shrinkage or response transformation
#' is applied. The result is on the native link scale (the response scale for
#' Laplace regression). Only a single prefix count is supported, not multiple
#' counts or single-tree mode. Other distributions, multiclass fits, formula
#' transformations/interactions, explicit offsets, malformed raw trees, invalid
#' internal children, and cyclic trees are rejected.
#'
#' Detectable offsets are rejected, including explicit zero offsets. If an
#' offset was discarded from all retained model metadata, it cannot be detected;
#' callers must not use such a fit. No offset is ever added to predictions.
#'
#' Numeric \code{NA} follows the missing branch; ordinary \code{NaN} follows the
#' right branch of a numeric split. Infinite values use the native strict
#' \code{<} comparison. Factor labels are matched to trained levels rather than
#' integer codes, so reordered or subset factor levels are safe. Missing and
#' unseen categorical labels follow the missing branch. Raw categorical split
#' indicators other than -1 (left) or 1 (right) also use the missing branch.
#' All R allocation, validation, and missing-value classification take place
#' outside OpenMP workers.
#'
#' On macOS, initialization rejects known active static LLVM OpenMP runtimes
#' and loaded XGBoost libraries that may embed static OpenMP, to avoid a process
#' abort. Use a separate fresh R process in these cases. These checks and shared
#' OpenMP linkage do not guarantee safe coexistence with every other runtime.
#'
#' @return A numeric vector of predictions, one per row of \code{newdata}.
#' @export
predict_omp <- function(model, newdata, n.trees, n_threads) {
  fail <- function(...) stop(..., call. = FALSE)
  scalar_int <- function(x, label, lower) {
    if (
      !is.numeric(x) ||
        length(x) != 1L ||
        is.na(x) ||
        !is.finite(x) ||
        x < lower ||
        x > .Machine$integer.max ||
        x != floor(x)
    ) {
      fail(label, " must be one integer >= ", lower)
    }
    as.integer(x)
  }
  if (
    !inherits(model, "GBMFit") ||
      !is.list(model$distribution) ||
      !identical(tolower(model$distribution$name), "laplace")
  ) {
    fail("Only gbm3 GBMFit Laplace regression models are supported")
  }
  if (
    !is.null(model$num.classes) && !identical(as.numeric(model$num.classes), 1)
  ) {
    fail("Multiclass models are unsupported")
  }
  if (
    length(model$initF) != 1L ||
      !is.numeric(model$initF) ||
      !is.finite(model$initF)
  ) {
    fail("Expected a finite scalar regression initF")
  }
  # Explicit offsets are rejected even if their training values happened to be zero.
  if (
    !is.null(attr(model$Terms, "offset")) ||
      !is.null(model$call$offset) ||
      !is.null(model$model$offset) ||
      !is.null(model$offset) ||
      (!is.null(model$gbm_data_obj$offset) &&
        anyNA(model$gbm_data_obj$offset)) ||
      (!is.null(model$gbm_data_obj$offset) &&
        any(model$gbm_data_obj$offset != 0))
  ) {
    fail("Offsets are unsupported")
  }
  vars <- model$variables
  names <- vars$var_names
  types <- vars$var_type
  levels <- vars$var_levels
  if (
    !is.character(names) ||
      !length(names) ||
      anyNA(names) ||
      anyDuplicated(names) ||
      length(types) != length(names) ||
      !is.numeric(types) ||
      anyNA(types) ||
      any(
        !is.finite(types) |
          types < 0 |
          types != floor(types) |
          types > .Machine$integer.max
      ) ||
      !is.list(levels) ||
      length(levels) != length(names)
  ) {
    fail("Invalid model$variables metadata")
  }
  if (!is.null(model$Terms)) {
    expressions <- as.list(attr(model$Terms, "variables"))[-1L]
    response <- attr(model$Terms, "response")
    if (length(response) && response > 0L) {
      expressions <- expressions[-response]
    }
    if (
      any(!vapply(expressions, is.symbol, logical(1))) ||
        any(attr(model$Terms, "order") != 1L)
    ) {
      fail("Formula transforms/interactions are unsupported")
    }
  }
  if (
    !is.data.frame(newdata) ||
      anyDuplicated(colnames(newdata)) ||
      !all(names %in% colnames(newdata))
  ) {
    fail("newdata must be a data.frame with each trained variable")
  }
  n.trees <- scalar_int(n.trees, "n.trees", 0)
  n_threads <- scalar_int(n_threads, "n_threads", 1)
  if (
    !is.list(model$trees) ||
      n.trees > length(model$trees) ||
      (!is.null(model$params$num_trees) && n.trees > model$params$num_trees)
  ) {
    fail("n.trees exceeds the fitted tree count")
  }
  if (!is.list(model$c.splits)) {
    fail("Expected raw model$c.splits")
  }
  x <- matrix(NA_real_, nrow = nrow(newdata), ncol = length(names))
  for (j in seq_along(names)) {
    column <- newdata[[names[[j]]]]
    if (types[[j]] > 0) {
      trained <- levels[[j]]
      if (
        !is.character(trained) ||
          length(trained) != types[[j]] ||
          anyNA(trained) ||
          anyDuplicated(trained)
      ) {
        fail("Invalid trained factor levels")
      }
      if (!is.factor(column) && !is.character(column)) {
        fail("Categorical variable must be factor/character: ", names[[j]])
      }
      # Match labels, not factor integer codes: reordered/subset levels are safe.
      # Both NA and unseen labels use the native missing branch.
      x[, j] <- as.double(match(as.character(column), trained) - 1L)
    } else {
      if (
        !(is.integer(column) || is.double(column)) ||
          is.object(column) ||
          !is.null(dim(column))
      ) {
        fail(
          "Numeric variable must be an ordinary numeric vector: ",
          names[[j]]
        )
      }
      x[, j] <- as.double(column)
    }
  }
  .Call(
    "gbm_predict_omp",
    x,
    model$trees,
    model$c.splits,
    as.integer(types),
    as.double(model$initF),
    n.trees,
    n_threads,
    PACKAGE = "gbm3"
  )
}
