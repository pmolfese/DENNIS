# ETAC-EEG in DENNIS

## Scope of the first implementation

DENNIS now exposes ETAC-EEG beside the existing fixed-threshold cluster-mass
and TFCE corrections in the Permutation Statistics view. It supports every
statistical design already handled by the shared backend:

- paired and independent t-tests;
- repeated-measures and between-subject omnibus F-tests;
- mixed interactions expressed as a within-subject difference measure compared
  between groups.

This is an **ETAC-style EEG adaptation**, not a byte-for-byte port of AFNI's
`3dXClustSim`. AFNI ETAC balances subtests over voxelwise thresholds, blur cases,
cluster figures of merit, and optionally spatially varying thresholds. DENNIS
uses exchangeability-respecting label permutations instead of simulated fMRI
random fields and balances a declared grid of cluster-forming p-values and
montage-relative EEG sensor-neighborhood radii.

The initial default threshold set is `[.05, .01, .005]`. These are explicit UI
parameters and are reported with their resolved t/F critical values. The default
radius multipliers are `[1.25, 1.7, 2.1] ×` the montage's median nearest-neighbor
spacing, spanning the immediate local ring through a modestly broader graph.

## Calibration

For permutation `p` and subtest `(threshold, radius)` combination `j`, DENNIS
records

`M[p,j] = maximum cluster mass over the complete channel × time lattice`.

The columns cannot be compared as raw masses because permissive thresholds
naturally create larger clusters. Calibration therefore proceeds as follows:

1. Rank each `M[p,j]` against the null column `M[:,j]` to obtain its marginal
   maximum-cluster p-value.
2. For every permutation, retain the minimum marginal p across the complete
   threshold × radius grid.
3. For an observed cluster, compute its marginal p within its own subtest.
4. Compare that p against the permutation distribution of minimum p-values.

This is a single-step permutation minP union. Equal marginal cutoffs make the
subtests equitable, while calibration of their minimum controls family-wise
error across the subtest grid and the full lattice without assuming the subtests
are independent. Exhaustive rearrangements use exact `count/N`
p-values; sampled rearrangements retain DENNIS's `(count + 1)/(N + 1)` rule.

The displayed ETAC regions are connected-component groupings of the union of
surviving subtest clusters. They are for inspection and plotting; inference
belongs to the calibrated subtest clusters, not to individual region members or
to precise onset/spatial boundaries.

## Architecture

- `ClusterPermutationAnalyzer` remains the shared statistic-map/permutation
  engine for t and F paths.
- `ClusterGrid` remains the shared connected-component implementation.
- `ETACCorrection` owns only scale normalization and joint union calibration.
- `ETACParameters` owns the explicit threshold and radius-multiplier sets.
- `ClusterSpatialAdjacency` resolves the montage's median nearest-neighbor
  spacing and constructs the nested distance graphs.
- `ClusterStatisticsRunner` and `ClusterPermutationAnalysis` keep t and F results
  in the same UI-facing shape used by cluster mass and TFCE.

The implementation stores `permutation count × threshold count × radius count`
scalar maxima, not all permuted statistic maps. Runtime grows approximately
linearly with the number of subtests; memory growth remains small.

## Relationship to ClustSim

A separate ACF-based ClustSim port is not needed for the current subject-level
EEG workflow. The existing fixed-threshold cluster-mass permutation path already
performs ClustSim's inferential job nonparametrically: it builds the null
distribution of the maximum cluster statistic at one declared threshold. An
explicit “ClustSim” label would currently duplicate that path and risk implying
parametric spatial-noise simulation that DENNIS does not perform.

## Validation completed

- exact rank-calibration tests with dependent and oppositely ranked subtests;
- invalid and duplicate threshold-set rejection;
- montage-relative spacing, nested-radius graph, and runner grid construction;
- deterministic behavior across all t/F designs and all three inference modes;
- planted spatiotemporal effects for t and omnibus F;
- the pre-existing cluster formation, exhaustive permutation, TFCE, and
  distribution suites remain green (159 tests across 21 suites).

## Next iteration decisions

1. **Cluster figure of merit.** Current ETAC-EEG uses cluster mass, matching the
   existing DENNIS result vocabulary. AFNI also supports extent and squared
   statistic weighting. These can be added as explicit choices after null-FWER
   and power simulations.
2. **Null validation harness.** Add a repeatable simulation/benchmark target that
   measures empirical FWER and power over many complete synthetic studies,
   separately for t/F and within/between designs.
3. **Side-by-side caching.** The current UI runs one correction at a time. A
   future shared permutation-statmap cache could compare cluster mass, TFCE, and
   ETAC on identical rearrangements without regenerating maps, at a substantial
   memory cost.
4. **Frequency dimension.** The current lattice is channel × time. A TF
   extension should add frequency adjacency to `ClusterGrid` rather than flatten
   frequency as if it were unrelated.

## Method references

- Cox RW. Equitable Thresholding and Clustering: A Novel Method for Functional
  Magnetic Resonance Imaging Clustering in AFNI. *Brain Connectivity*. 2019;
  9(7):529–538. https://doi.org/10.1089/brain.2019.0666
- AFNI `3dXClustSim` documentation:
  https://afni.nimh.nih.gov/pub/dist/doc/program_help/3dXClustSim.html
- Maris E, Oostenveld R. Nonparametric statistical testing of EEG- and MEG-data.
  *Journal of Neuroscience Methods*. 2007;164(1):177–190.
- Westfall PH, Young SS. *Resampling-Based Multiple Testing*. Wiley; 1993.
