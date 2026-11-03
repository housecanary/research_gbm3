# gbm3: Generalized Boosted Models

<!-- badges: start -->
[![R-CMD-check](https://github.com/gbm-developers/gbm3/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/gbm-developers/gbm3/actions/workflows/R-CMD-check.yaml)
[![pkgdown](https://github.com/gbm-developers/gbm3/actions/workflows/pkgdown.yaml/badge.svg)](https://github.com/gbm-developers/gbm3/actions/workflows/pkgdown.yaml)
<!-- badges: end -->

Originally written by Greg Ridgeway between 1999-2003, added to by various 
authors, extensively updated and polished by James Hickey in 2016, survival 
models greatly improved by Terry Therneau in 2016, and currently 
maintained by Greg Ridgeway.
Development is discussed at the
[gbm-dev Google Group](https://groups.google.com/forum/#!forum/gbm-dev).

`gbm3` provides generalized boosted regression models with a newer API than the
original `gbm` package. The package supports regression, classification,
survival models, and learning-to-rank methods. OpenMP compilation is required
for fitting and prediction.

Documentation and vignettes are available at
<https://gbm-developers.github.io/gbm3/>.

To install the development version from GitHub, first install `remotes`:

```R
install.packages("remotes")
```

Then install `gbm3`:

```R
remotes::install_github("gbm-developers/gbm3")

# or to build vignettes during installation
remotes::install_github("gbm-developers/gbm3", build_vignettes = TRUE, force = TRUE)
```

## Building with OpenMP

Install from any local checkout path using ordinary package installation:

```R
pak::local_install("/path/to/gbm3_2026_11")
```

Installation configures and compiles the native code once; package loading does
not use `sourceCpp()` or build code. Configuration uses `R CMD SHLIB` with the
same C++11 compiler, site/user Makevars and flags as the package build, and
requires a linked **shared** OpenMP runtime and an actual two-thread team. It
fails rather than silently producing a serial build. Package loading also
checks the two-thread capability. Do not set `OMP_THREAD_LIMIT` below two;
`OMP_DYNAMIC` must also permit the requested two-thread team. Configuration does
not disable dynamic teams behind the runtime's back.

**Linux:** install R development tools, GNU make, binutils, GCC/G++ and the
matching shared `libgomp` runtime (for example, `r-base-dev`, `build-essential`
and `binutils` on Debian/Ubuntu). R's configured OpenMP flags are tried first;
`-fopenmp` is tried with the same configured compiler if necessary. No compiler
or runtime is bundled, and no system packages are installed automatically.

**macOS:** install Xcode Command Line Tools (`xcode-select --install`) and,
for Apple clang, Homebrew's shared runtime:

```sh
brew install libomp
```

A compatible OpenMP compiler already configured in R's Makevars takes
precedence (including GCC with shared `libgomp`). Only if the configured compiler
is verified as Apple clang is it probed with Homebrew's `omp.h` and
**`libomp.dylib`**, discovered via
`brew --prefix libomp` or the usual Intel/Apple Silicon prefixes. The compiler,
R and runtime architectures must match. This does not edit `~/.R/Makevars`,
replace R's compiler configuration or require a particular checkout location.
If R links additional Fortran code/libraries, its configured GNU Fortran and
runtime libraries must remain compatible too; gbm3 itself has no Fortran source.

On macOS, `configure` discovers the active SDK using
`xcrun --sdk macosx --show-sdk-path`. Generated package-local Makevars adds the
same SDK to header compilation (`-isysroot`) and linking (`-isysroot` and the
explicit linker `-syslibroot`), including for GCC. This prevents missing SDK
headers or `ld: library 'System' not found` without replacing the configured
compiler, user flags, or global settings. The selected SDK and inherited
`SDKROOT` / `MACOSX_DEPLOYMENT_TARGET` are printed for diagnosis; neither
environment variable nor the deployment target is changed. Keep those settings
compatible with the active SDK and toolchain. A missing SDK is a configuration
error. GCC is never given Apple clang's `-Xpreprocessor`/Homebrew-header fallback.

**Windows:** use the Rtools version matching R; its GCC/OpenMP toolchain is
probed through `configure.win` using the same C++11 build settings.

**Shared-runtime caveat:** do not substitute a static `libomp.a`, use
`-static-libgomp`, or suppress duplicate-runtime errors with
`KMP_DUPLICATE_LIB_OK`. A pre-existing XGBoost build that embeds static OpenMP
can still conflict with a shared runtime loaded by another package. Rebuild
that dependency with compatible shared OpenMP (or isolate it in another R
process); linking another static runtime into gbm3 is not a safe remedy.

Generated `src/Makevars` / `src/Makevars.win` are installation artifacts;
`cleanup` removes them, and each installation probes the local toolchain anew.

If an older user-configured Homebrew GCC is incompatible with the current
macOS SDK (for example, `FILE` errors from GCC's `include-fixed/stdio.h`),
explicitly select Apple clang for this installation only:

```sh
R_MAKEVARS_USER="$(pwd)/gbm3_2026_11/tools/Makevars-macos" \
  MAKEFLAGS="-j$(sysctl -n hw.logicalcpu)" \
  R -e "pak::local_install('gbm3_2026_11')"
```

Run this from the parent checkout directory. The override does not modify
`~/.R/Makevars`; it replaces its settings only for this install process.
Install Homebrew `gcc` as well as `libomp`. The override discovers `gfortran`
on `PATH` (falling back to `brew --prefix gcc`) and queries that compiler for
the exact `libgfortran.dylib` and `libquadmath.dylib` locations. It overrides
R's stale `/opt/gfortran` linker paths for dependencies such as Matrix too;
no Intel or Apple Silicon Homebrew prefix is hardcoded. R, the compiler and
the libraries must still have matching architectures.

`MAKEFLAGS` parallelizes compilation within each package using all logical
cores. Use a smaller value such as `MAKEFLAGS="-j4"` to limit memory use;
multiple simultaneous package builds can otherwise oversubscribe the machine.

## Parallel Laplace prediction

```r
gbm3::predict_omp(model, newdata, n.trees = 100L, n_threads = 4L)
```

The four arguments match the standalone `predict_gbm_parallel()` helper; no
initialization call, source directory or writable runtime cache is needed.
After `library(gbm3)`, `predict_omp()` is also available without the namespace
prefix. Existing `predict()` methods are unchanged.

Only Laplace `GBMFit` regression models are supported, with one tree-prefix
count (including zero). Other losses, offsets, formula transformations and
interactions are rejected. Offsets discarded from all model metadata cannot
be detected: do not pass such models. See `?gbm3::predict_omp` for the full
contract. Each call validates/copies its inputs; speedup depends on workload.

When this package is a submodule of `research_gbm3`, a plain clone does not
populate it. Initialize the recorded submodule revision before installation:

```dockerfile
RUN git clone https://github.com/housecanary/research_gbm3.git /data/gbm3 \
    && git -C /data/gbm3 submodule update --init gbm3_2026_11
RUN R -e "pak::local_install('/data/gbm3/gbm3_2026_11')"
```

Publish this branch to a repository you can push to and set the parent's
`.gitmodules` URL to that repository. Push the submodule commit first, then
commit/push its updated pointer in the parent. A local submodule branch alone
does not make these changes available to Docker. For reproducible builds,
also check out a reviewed parent commit before initializing its submodule.

