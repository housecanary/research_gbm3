local_edition(3)

omp_test_model <- function(categorical = FALSE) {
  structure(
    list(
      distribution = list(name = "Laplace"),
      num.classes = 1,
      initF = 10,
      variables = list(
        var_names = "x",
        var_type = if (categorical) 5L else 0L,
        var_levels = list(if (categorical) letters[1:5] else character())
      ),
      params = list(num_trees = 1L),
      trees = list(list(
        c(0L, -1L, -1L, -1L),
        c(0, -2, 3, 7),
        c(1L, -1L, -1L, -1L),
        c(2L, -1L, -1L, -1L),
        c(3L, -1L, -1L, -1L),
        rep(0, 4),
        rep(1, 4),
        rep(0, 4)
      )),
      c.splits = if (categorical) {
        list(c(-1L, 1L, 0L, NA_integer_, 2L))
      } else {
        list()
      }
    ),
    class = "GBMFit"
  )
}

omp_test_errors <- function(cases) {
  for (label in names(cases)) {
    error <- tryCatch(cases[[label]](), error = identity)
    expect_s3_class(error, "error")
    cat(label, ": ", conditionMessage(error), "\n", sep = "")
  }
}

test_that("fresh processes support per-call teams and single-thread limits", {
  skip_if_not_installed("callr")
  run <- function(limit) {
    callr::r(
      function(model, limit) {
        library(gbm3)
        data <- data.frame(x = rep(1, 8))
        counts <- if (limit == 1L) c(1L, 4L, 2L, 1L) else c(1L, 4L, 2L)
        lapply(counts, function(threads) {
          tryCatch(
            predict_omp(model, data, 1L, threads),
            error = function(e) conditionMessage(e)
          )
        })
      },
      args = list(omp_test_model(), limit),
      libpath = .libPaths(),
      env = c(
        OMP_THREAD_LIMIT = as.character(limit),
        OMP_DYNAMIC = "TRUE",
        OMP_NUM_THREADS = "1"
      )
    )
  }
  expect_identical(run(4L), rep(list(rep(13, 8)), 3))
  expect_identical(
    run(1L),
    list(
      rep(13, 8),
      "OpenMP created 1 threads; requested 4",
      "OpenMP created 1 threads; requested 2",
      rep(13, 8)
    )
  )
})

test_that("predict_omp is exported with four mandatory arguments and two threads", {
  expect_identical(getExportedValue("gbm3", "predict_omp"), predict_omp)
  expect_identical(
    as.list(formals(predict_omp)),
    alist(model = , newdata = , n.trees = , n_threads = )
  )
  routines <- getDLLRegisteredRoutines(getLoadedDLLs()[["gbm3"]])$.Call
  expect_identical(routines[["gbm_omp_team_size"]]$numParameters, 1L)
  withr::local_seed(7489)
  rng <- .Random.seed
  expect_identical(.Call("gbm_omp_team_size", 2L, PACKAGE = "gbm3"), 2L)
  expect_identical(.Random.seed, rng)
})

test_that("prediction does not create an absent RNG state", {
  had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  if (had_seed) {
    saved_seed <- get(".Random.seed", envir = .GlobalEnv)
  }
  withr::defer({
    if (had_seed) {
      assign(".Random.seed", saved_seed, envir = .GlobalEnv)
    } else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) {
      rm(".Random.seed", envir = .GlobalEnv)
    }
  })
  if (had_seed) {
    rm(".Random.seed", envir = .GlobalEnv)
  }
  model <- omp_test_model()
  for (threads in 1:2) {
    expect_identical(
      predict_omp(model, data.frame(x = 1:2), 1L, threads),
      c(13, 13)
    )
  }
  expect_identical(.Call("gbm_omp_team_size", 2L, PACKAGE = "gbm3"), 2L)
  expect_identical(
    exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE),
    FALSE
  )
})

test_that("Laplace prefixes match base and native predictions exactly", {
  withr::local_seed(7489)
  d <- data.frame(
    continuous = rnorm(240),
    another_number = sample.int(100L, 240, replace = TRUE),
    category = factor(sample(c("red", "green", "blue"), 240, TRUE)),
    other_category = factor(sample(c("a", "b"), 240, TRUE))
  )
  d$continuous[c(4, 17)] <- NA_real_
  d$category[c(6, 18)] <- NA
  y <- 2 *
    ifelse(is.na(d$continuous), 0, d$continuous) +
    ifelse(is.na(d$category), 0, as.integer(d$category)) +
    rnorm(240, sd = 0.1)

  for (fields in list(
    c("continuous", "another_number"),
    c("category", "other_category"),
    names(d)
  )) {
    training <- d[, fields, drop = FALSE]
    model <- gbmt_fit(
      training,
      y,
      distribution = gbm_dist("Laplace"),
      train_params = training_params(
        num_trees = 17,
        interaction_depth = 3,
        min_num_obs_in_node = 3,
        shrinkage = 0.07,
        bag_fraction = 0.8,
        num_train = nrow(training),
        num_features = ncol(training)
      ),
      keep_gbm_data = TRUE
    )
    test <- training[seq_len(61), , drop = FALSE]
    for (field in fields) {
      if (is.factor(test[[field]])) {
        values <- as.character(test[[field]])
        values[c(2, 3)] <- c("UNSEEN", NA_character_)
        test[[field]] <- factor(
          values,
          levels = c(rev(levels(training[[field]])), "UNSEEN")
        )
      } else {
        test[[field]] <- as.double(test[[field]])
        test[[field]][1:4] <- c(NA_real_, NaN, Inf, -Inf)
      }
    }
    encoded <- test
    for (j in seq_along(fields)) {
      if (model$variables$var_type[j] > 0) {
        encoded[[j]] <- as.double(
          match(as.character(test[[j]]), model$variables$var_levels[[j]]) - 1L
        )
      }
    }
    for (count in c(0L, 1L, 6L, 17L)) {
      rng <- .Random.seed
      base <- as.double(stats::predict(
        model,
        test,
        n.trees = count,
        type = "link"
      ))
      native <- .Call(
        "gbm_pred",
        as.matrix(encoded),
        count,
        model$initF,
        model$trees,
        model$c.splits,
        as.integer(model$variables$var_type),
        0L,
        PACKAGE = "gbm3"
      )
      serial <- predict_omp(model, test, count, 1L)
      expect_identical(serial, base)
      expect_identical(serial, as.double(native))
      expect_identical(predict_omp(model, test, count, 2L), serial)
      if (count == 0L) {
        expect_identical(serial, rep(model$initF, nrow(test)))
      }
      expect_identical(
        predict_omp(model, test[FALSE, , drop = FALSE], count, 2L),
        numeric()
      )
      expect_identical(
        predict_omp(model, test[1, , drop = FALSE], count, 2L),
        serial[1]
      )
      expect_identical(.Random.seed, rng)
    }
    reordered <- test[, rev(fields), drop = FALSE]
    reordered$irrelevant <- "ignored"
    characters <- test
    for (field in fields) {
      if (is.factor(characters[[field]])) {
        characters[[field]] <- as.character(characters[[field]])
      }
    }
    expected <- predict_omp(model, test, 17L, 2L)
    expect_identical(predict_omp(model, reordered, 17L, 2L), expected)
    expect_identical(predict_omp(model, characters, 17L, 2L), expected)
  }
})

test_that("numeric and categorical branches preserve native special-value semantics", {
  model <- omp_test_model()
  test <- data.frame(x = c(NA_real_, NaN, Inf, -Inf, 0, -1))
  for (threads in 1:2) {
    expect_identical(
      predict_omp(model, test, 1L, threads),
      c(17, 13, 13, 8, 13, 8)
    )
    expect_identical(
      predict_omp(model, data.frame(x = c(-1L, 0L)), 1L, threads),
      c(8, 13)
    )
  }
  model <- omp_test_model(TRUE)
  values <- c(letters[1:5], NA_character_, "UNSEEN")
  for (x in list(
    values,
    factor(values, levels = c("UNSEEN", rev(letters[1:5])))
  )) {
    for (threads in 1:2) {
      expect_identical(
        predict_omp(model, data.frame(x), 1L, threads),
        c(8, 13, 17, 17, 17, 17, 17)
      )
    }
  }
  expect_identical(
    predict_omp(
      model,
      data.frame(x = factor(c("b", "a"), levels = c("b", "a"))),
      1L,
      2L
    ),
    c(13, 8)
  )
})

test_that("invalid arguments and columns produce concise diagnostics", {
  model <- omp_test_model()
  data <- data.frame(x = 1:2)
  expect_snapshot(omp_test_errors(list(
    missing_model = \() {
      predict_omp(newdata = data, n.trees = 1L, n_threads = 2L)
    },
    missing_newdata = \() predict_omp(model, n.trees = 1L, n_threads = 2L),
    missing_trees = \() predict_omp(model, data, n_threads = 2L),
    missing_threads = \() predict_omp(model, data, 1L),
    matrix = \() predict_omp(model, as.matrix(data), 1L, 2L),
    missing_column = \() predict_omp(model, data.frame(y = 1:2), 1L, 2L),
    duplicate_column = \() {
      predict_omp(model, setNames(data.frame(1:2, 3:4), c("x", "x")), 1L, 2L)
    },
    numeric_character = \() predict_omp(model, data.frame(x = "1"), 1L, 2L),
    numeric_factor = \() {
      predict_omp(model, data.frame(x = factor("a")), 1L, 2L)
    },
    numeric_logical = \() predict_omp(model, data.frame(x = TRUE), 1L, 2L),
    numeric_object = \() predict_omp(model, data.frame(x = Sys.Date()), 1L, 2L),
    numeric_matrix = \() {
      predict_omp(model, data.frame(x = I(matrix(1, 2, 1))), 1L, 2L)
    },
    categorical_numeric = \() predict_omp(omp_test_model(TRUE), data, 1L, 2L)
  )))
  cases <- list()
  for (argument in c("n.trees", "n_threads")) {
    invalid <- list(
      null = NULL,
      empty = integer(),
      vector = c(1, 2),
      na = NA_real_,
      nan = NaN,
      infinite = Inf,
      negative = -1,
      fractional = 0.5,
      character = "1",
      logical = TRUE,
      overflow = .Machine$integer.max + 1
    )
    if (argument == "n_threads") {
      invalid <- c(invalid, list(zero = 0))
    }
    for (label in names(invalid)) {
      args <- list(model = model, newdata = data, n.trees = 1L, n_threads = 2L)
      args[argument] <- invalid[label]
      cases[[paste(argument, label, sep = "_")]] <- local({
        saved <- args
        \() do.call(predict_omp, saved)
      })
    }
  }
  expect_snapshot(omp_test_errors(cases))
  expect_snapshot(error = TRUE, predict_omp(model, data, 2L, 2L))
})

test_that("unsupported models, offsets and formulas are rejected", {
  model <- omp_test_model()
  data <- data.frame(x = 1:2)
  check <- function(field, value) {
    bad <- model
    bad[[field]] <- value
    predict_omp(bad, data, 1L, 2L)
  }
  expect_snapshot(omp_test_errors(list(
    wrong_class = \() predict_omp(unclass(model), data, 1L, 2L),
    distribution = \() check("distribution", list(name = "Gaussian")),
    multiclass = \() check("num.classes", 2),
    init_missing = \() check("initF", NA_real_),
    init_infinite = \() check("initF", Inf),
    init_vector = \() check("initF", c(1, 2)),
    init_character = \() check("initF", "1"),
    offset_terms = \() check("Terms", terms(y ~ x + offset(x))),
    offset_call = \() check("call", quote(gbmt(offset = 0))),
    offset_model = \() check("model", list(offset = 0)),
    offset_explicit_zero = \() check("offset", 0),
    offset_retained = \() check("gbm_data_obj", list(offset = c(0, 1))),
    offset_retained_na = \() check("gbm_data_obj", list(offset = NA_real_)),
    transform = \() check("Terms", terms(y ~ log(x))),
    interaction = \() check("Terms", terms(y ~ x:z)),
    trees = \() check("trees", NULL),
    tree_count = \() check("params", list(num_trees = 0L)),
    splits = \() check("c.splits", NULL)
  )))
  for (terms in list(terms(y ~ x), terms(~x))) {
    model$Terms <- terms
    expect_identical(predict_omp(model, data, 1L, 2L), c(13, 13))
  }
  model$gbm_data_obj <- list(offset = c(0, 0))
  expect_identical(predict_omp(model, data, 1L, 2L), c(13, 13))
})

test_that("invalid variable metadata is rejected", {
  check <- function(field, value, categorical = FALSE) {
    model <- omp_test_model(categorical)
    model$variables[field] <- list(value)
    data <- data.frame(x = if (categorical) "a" else 1)
    predict_omp(model, data, 1L, 2L)
  }
  expect_snapshot(omp_test_errors(list(
    names_missing = \() check("var_names", NA_character_),
    names_empty = \() check("var_names", character()),
    names_duplicate = \() check("var_names", c("x", "x")),
    types_missing = \() check("var_type", NA_integer_),
    types_negative = \() check("var_type", -1L),
    types_fractional = \() check("var_type", 0.5),
    types_infinite = \() check("var_type", Inf),
    levels_not_list = \() check("var_levels", "a"),
    levels_length = \() check("var_levels", list()),
    trained_level_count = \() check("var_levels", list("a"), TRUE),
    trained_level_missing = \() {
      check("var_levels", list(c(letters[1:4], NA_character_)), TRUE)
    },
    trained_level_duplicate = \() check("var_levels", list(rep("a", 5)), TRUE)
  )))
})

test_that("malformed raw trees and cycles are rejected before traversal", {
  check <- function(
    field = NULL,
    value = NULL,
    tree = NULL,
    categorical = FALSE,
    splits = NULL
  ) {
    model <- omp_test_model(categorical)
    if (!is.null(tree)) {
      model$trees[[1]] <- tree
    }
    if (!is.null(field)) {
      model$trees[[1]][field] <- list(value)
    }
    if (!is.null(splits)) {
      model$c.splits <- splits
    }
    predict_omp(model, data.frame(x = if (categorical) "a" else 1), 1L, 2L)
  }
  tree <- omp_test_model()$trees[[1]]
  cycle <- tree
  cycle[[3]][1] <- 0L
  disconnected <- tree
  disconnected[[1]][4] <- 0L
  for (field in 3:5) {
    disconnected[[field]][4] <- 3L
  }
  expect_snapshot(omp_test_errors(list(
    raw_list = \() check(tree = 1:8),
    field_count = \() check(tree = tree[-8]),
    empty_nodes = \() check(tree = lapply(tree, \(x) x[FALSE])),
    integer_field = \() check(1L, as.double(tree[[1]])),
    double_field = \() check(2L, as.integer(tree[[2]])),
    matrix_field = \() check(2L, matrix(tree[[2]], 4, 1)),
    field_lengths = \() check(8L, 0),
    variable_index = \() check(1L, c(1L, -1L, -1L, -1L)),
    variable_na = \() check(1L, c(NA_integer_, -1L, -1L, -1L)),
    child_negative = \() check(3L, c(-1L, -1L, -1L, -1L)),
    child_out_of_range = \() check(4L, c(4L, -1L, -1L, -1L)),
    child_missing = \() check(5L, c(NA_integer_, -1L, -1L, -1L)),
    split_index = \() check(2L, c(1, -2, 3, 7), categorical = TRUE),
    split_fractional = \() check(2L, c(0.5, -2, 3, 7), categorical = TRUE),
    split_nonfinite = \() check(2L, c(Inf, -2, 3, 7), categorical = TRUE),
    split_length = \() check(categorical = TRUE, splits = list(c(-1L, 1L))),
    split_type = \() check(categorical = TRUE, splits = list(rep(0, 5))),
    cycle = \() check(tree = cycle),
    disconnected_cycle = \() check(tree = disconnected)
  )))
  model <- omp_test_model()
  model$trees[[2]] <- cycle
  model$params$num_trees <- 2L
  expect_identical(predict_omp(model, data.frame(x = 1:2), 1L, 2L), c(13, 13))
  expect_identical(
    predict_omp(model, data.frame(x = numeric()), 0L, 2L),
    numeric()
  )
})
