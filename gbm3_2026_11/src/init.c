#include <R.h>
#include <Rinternals.h>
#include <stdlib.h> // for NULL
#include <R_ext/Rdynload.h>

/* FIXME: 
   Check these declarations against the C/Fortran source code.
   Generated with:
     tools::package_native_routine_registration_skeleton('.')
     replacing void * with SEXP
*/

/* .Call calls */
extern SEXP gbm(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP gbm_plot(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP gbm_pred(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP gbm_predict_omp(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP gbm_omp_team_size(SEXP);

static const R_CallMethodDef CallEntries[] = {
    {"gbm",      (DL_FUNC) &gbm,      25},
    {"gbm_plot", (DL_FUNC) &gbm_plot,  7},
    {"gbm_pred", (DL_FUNC) &gbm_pred,  7},
    {"gbm_predict_omp", (DL_FUNC) &gbm_predict_omp, 7},
    {"gbm_omp_team_size", (DL_FUNC) &gbm_omp_team_size, 1},
    {NULL, NULL, 0}
};

void R_init_gbm3(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}