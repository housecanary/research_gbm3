# gbm3 (development version)

* `predict_omp()` adds row-parallel Laplace prediction with the draft predictor's four-argument API. Installation requires a shared OpenMP runtime but supports single-thread environments; namespace loading no longer creates a thread team. Each prediction requests its own team size with dynamic sizing temporarily disabled, preserves the caller's runtime policy, and errors if hard limits prevent the requested team.
