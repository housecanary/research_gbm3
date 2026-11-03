// Experimental raw gbm3 GBMFit link-scale predictor; no refit or shrinkage.
// Source checked (public retrieval, 2026-11-02): gbm-developers/gbm3,
// commit 98edaf5c4f7e369893886a95fa01c31514375f8d:
// https://github.com/gbm-developers/gbm3/blob/98edaf5c4f7e369893886a95fa01c31514375f8d/src/gbmentry.cpp#L225-L319
// Native uses ISNA (not !isfinite), strict numeric <, categorical indicators
// -1/1/other => left/right/missing, and terminal splitcodepred (field 1).
// terminal_strategy.h:53-66 serializes already-shrunken terminal predictions;
// categorical_strategy.h:145-158 serializes zero-based c.split indices.
//
// Contract: double matrix in trained-variable order, factors encoded with the
// model's zero-based level ordering; var_type is an integer category-count
// vector. Each tree is the raw eight-field unnamed list, NOT pretty.gbm.tree.
// n_trees is one scalar prefix count, including zero. No response transform,
// offset, single.tree mode, multiple requested counts, or multiclass support.
// Numeric NA => missing; ordinary NaN => right; +/-Inf use native comparison.
// Categorical NA => missing; nonfinite/negative/fractional non-NA encodings are
// rejected: native int casts/indexing are unsafe or outside the input contract.
// Valid nonnegative unseen category codes => missing (no out-of-bounds cast).
// Internal children must be valid nodes; child=-1 is rejected, not imputed.
// Exact-native equivalence is only claimed for valid native trees/encodings.
// All model/data copies, R NA classification, validation and R allocation occur
// on the main thread. Workers touch only STL buffers and do not call the R API.
// OpenMP is mandatory. Do not use fast-math (it breaks NA/NaN/Inf semantics).

#include <Rcpp.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <utility>
#include <vector>
#if defined(__FAST_MATH__) || (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__ > 0)
#error "gbm3 predict_omp requires NA/NaN/Inf semantics: disable fast-math and finite-math-only"
#endif
#ifndef _OPENMP
#error "gbm3 predict_omp requires OpenMP: configure the compiler and runtime"
#endif
#include <omp.h>

namespace {
class FixedTeam {
 public:
  FixedTeam() : dynamic_(omp_get_dynamic()) { omp_set_dynamic(0); }
  ~FixedTeam() { omp_set_dynamic(dynamic_); }
 private:
  int dynamic_;
};

int validated_gbm_team_size(int requested) {
  if (requested == NA_INTEGER || requested < 1)
    Rcpp::stop("requested thread count must be positive");
  int actual = 1;
  FixedTeam team_policy;
#pragma omp parallel num_threads(requested)
  {
#pragma omp single
    actual = omp_get_num_threads();
  }
  return actual;
}

struct Tree {
  std::vector<int> splitvar, left, right, missing;
  std::vector<double> splitcodepred, improvement, weight, prediction;
};

std::vector<int> copy_int(SEXP value, const char* label) {
  if (TYPEOF(value) != INTSXP || Rf_isMatrix(value))
    Rcpp::stop("%s must be an integer vector", label);
  Rcpp::IntegerVector v(value);
  return std::vector<int>(v.begin(), v.end());
}

std::vector<double> copy_double(SEXP value, const char* label) {
  if (TYPEOF(value) != REALSXP || Rf_isMatrix(value))
    Rcpp::stop("%s must be a double vector", label);
  Rcpp::NumericVector v(value);
  return std::vector<double>(v.begin(), v.end());
}

void validate_tree(const Tree& t, const std::vector<int>& types,
                   const std::vector<std::vector<int> >& cats) {
  const std::size_t n = t.splitvar.size();
  if (n == 0 || n > static_cast<std::size_t>(std::numeric_limits<int>::max()))
    Rcpp::stop("Each selected tree must have 1..INT_MAX nodes");
  if (t.splitcodepred.size() != n || t.left.size() != n ||
      t.right.size() != n || t.missing.size() != n ||
      t.improvement.size() != n || t.weight.size() != n ||
      t.prediction.size() != n)
    Rcpp::stop("All eight tree fields must have equal lengths");

  for (std::size_t k = 0; k < n; ++k) {
    const int v = t.splitvar[k];
    if (v == -1) continue;  // terminal children conventionally equal -1
    if (v < 0 || static_cast<std::size_t>(v) >= types.size())
      Rcpp::stop("Invalid split-variable index");
    const int children[] = {t.left[k], t.right[k], t.missing[k]};
    for (int child : children)
      if (child < 0 || static_cast<std::size_t>(child) >= n)
        Rcpp::stop("Invalid internal child index: child=-1 is unsupported");
    const double code = t.splitcodepred[k];
    if (types[v] > 0) {
      if (!std::isfinite(code) || code < 0 || std::floor(code) != code ||
          code >= static_cast<double>(cats.size()))
        Rcpp::stop("Invalid zero-based c.split index");
      if (cats[static_cast<std::size_t>(code)].size() !=
          static_cast<std::size_t>(types[v]))
        Rcpp::stop("c.split length disagrees with var_type category count");
    }
  }

  // Iterative DFS validates all components, preventing cycles/infinite walks.
  std::vector<unsigned char> color(n, 0);
  std::vector<std::pair<int, int> > stack;
  for (std::size_t root = 0; root < n; ++root) {
    if (color[root]) continue;
    color[root] = 1;
    stack.push_back(std::make_pair(static_cast<int>(root), 0));
    while (!stack.empty()) {
      const int node = stack.back().first;
      int& edge = stack.back().second;
      if (t.splitvar[node] == -1 || edge == 3) {
        color[node] = 2;
        stack.pop_back();
        continue;
      }
      const int next = edge == 0 ? t.left[node] :
                       edge == 1 ? t.right[node] : t.missing[node];
      ++edge;
      if (color[next] == 1) Rcpp::stop("Cycle detected in tree");
      if (color[next] == 0) {
        color[next] = 1;
        stack.push_back(std::make_pair(next, 0));
      }
    }
  }
}
Rcpp::NumericVector validated_gbm_predict(
    Rcpp::NumericMatrix x, Rcpp::List trees, Rcpp::List c_splits,
    Rcpp::IntegerVector var_type, double initF, int n_trees,
    int n_threads) {
  if (n_trees == NA_INTEGER || n_trees < 0 ||
      static_cast<R_xlen_t>(n_trees) > trees.size())
    Rcpp::stop("n_trees must be a scalar prefix count in [0, length(trees)]");
  if (n_threads == NA_INTEGER || n_threads < 1)
    Rcpp::stop("n_threads must be positive");
  const int nr = x.nrow(), nc = x.ncol();
  if (var_type.size() != nc) Rcpp::stop("x columns must match var_type");
  const std::vector<int> types(var_type.begin(), var_type.end());
  for (int type : types)
    if (type == NA_INTEGER || type < 0)
      Rcpp::stop("var_type must contain nonnegative category counts");

  std::vector<std::vector<int> > cats;
  cats.reserve(static_cast<std::size_t>(c_splits.size()));
  for (R_xlen_t k = 0; k < c_splits.size(); ++k)
    cats.push_back(copy_int(c_splits[k], "c.split element"));
  // Preserve all indicator values: native treats anything other than -1/1 as
  // missing, including zero and NA_INTEGER.
  std::vector<Tree> model;
  model.reserve(static_cast<std::size_t>(n_trees));
  for (int k = 0; k < n_trees; ++k) {
    Rcpp::checkUserInterrupt();
    SEXP raw = trees[k];
    if (TYPEOF(raw) != VECSXP || Rf_xlength(raw) != 8)
      Rcpp::stop("Each selected tree must be a raw list of eight vectors");
    Rcpp::List fields(raw);
    Tree t;
    t.splitvar = copy_int(fields[0], "splitvar");
    t.splitcodepred = copy_double(fields[1], "splitcodepred");
    t.left = copy_int(fields[2], "left");
    t.right = copy_int(fields[3], "right");
    t.missing = copy_int(fields[4], "missing");
    t.improvement = copy_double(fields[5], "improvement");
    t.weight = copy_double(fields[6], "weight");
    t.prediction = copy_double(fields[7], "prediction");
    validate_tree(t, types, cats);
    model.push_back(std::move(t));
  }

  const std::vector<double> data(x.begin(), x.end());
  std::vector<unsigned char> is_na(data.size());
  for (int col = 0; col < nc; ++col) {
    Rcpp::checkUserInterrupt();
    const std::size_t base = static_cast<std::size_t>(col) * nr;
    for (int row = 0; row < nr; ++row) {
      const std::size_t at = base + row;
      const double value = data[at];
      is_na[at] = R_IsNA(value);  // exactly native ISNA, main thread only
      if (types[col] > 0 && !is_na[at] &&
          (!std::isfinite(value) || value < 0 || std::floor(value) != value))
        Rcpp::stop("Categorical data must be NA or finite nonnegative integer codes");
    }
  }

  std::vector<double> result(static_cast<std::size_t>(nr), initF);
  const int workers = std::max(1, std::min(n_threads, nr));
  int actual = 0;
  {
  // Restore the caller's policy before any R error or interrupt handling.
  FixedTeam team_policy;
#pragma omp parallel num_threads(workers) if(workers > 1)
  {
#pragma omp single
    actual = omp_get_num_threads();
#pragma omp for schedule(static)
    for (int row = 0; row < nr; ++row) {
      double score = initF;
      for (const Tree& t : model) {
        int node = 0;
        while (t.splitvar[node] != -1) {
          const int var = t.splitvar[node];
          const std::size_t at = static_cast<std::size_t>(var) * nr + row;
          const double value = data[at];
          int next = t.missing[node];
          if (!is_na[at]) {
            if (types[var] == 0) {
              next = value < t.splitcodepred[node] ? t.left[node] : t.right[node];
            } else {
              const std::vector<int>& route =
                  cats[static_cast<std::size_t>(t.splitcodepred[node])];
              if (value < static_cast<double>(route.size())) {
                const int indicator = route[static_cast<std::size_t>(value)];
                if (indicator == -1) next = t.left[node];
                else if (indicator == 1) next = t.right[node];
              }
            }
          }
          node = next;
        }
        score += t.splitcodepred[node];
      }
      result[row] = score;  // independent rows; native tree accumulation order
    }
  }
  }
  if (actual != workers)
    Rcpp::stop("OpenMP created %d threads; requested %d", actual, workers);
  Rcpp::checkUserInterrupt();
  return Rcpp::NumericVector(result.begin(), result.end());
}
}  // namespace

extern "C" SEXP gbm_omp_team_size(SEXP requested) {
  BEGIN_RCPP
  return Rcpp::wrap(validated_gbm_team_size(Rcpp::as<int>(requested)));
  END_RCPP
}

extern "C" SEXP gbm_predict_omp(SEXP x, SEXP trees, SEXP c_splits,
                               SEXP var_type, SEXP initF, SEXP n_trees,
                               SEXP n_threads) {
  BEGIN_RCPP
  return validated_gbm_predict(
      Rcpp::NumericMatrix(x), Rcpp::List(trees), Rcpp::List(c_splits),
      Rcpp::IntegerVector(var_type), Rcpp::as<double>(initF),
      Rcpp::as<int>(n_trees), Rcpp::as<int>(n_threads));
  END_RCPP
}
