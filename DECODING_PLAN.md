# DENNIS Decoding / Classification Plan

## Goal

Add a new `Decoding / Classification` tab between `Tensor` and `Waveform Analysis`.
The tab should handle multivariate pattern classification for EEG/ERP data in a
way that approximates MVPA workflows now, while leaving a clean path to true
single-trial decoding later.

DENNIS currently works primarily with averaged `.mff` ERP condition data assembled
as:

```text
channels x time x condition x subject
```

Classic EEG MVPA usually wants single-trial epochs, so the first version should
be honest about its scope: average-based condition/group decoding, subject-safe
cross-validation, and ERP pattern analyses that reuse the existing tensor and
label infrastructure.

## Integration Points

- Add an `AppMode` case in `DENNIS/Model/AnalysisStore.swift`:
  - `case decoding = "Decoding / Classification"`
- Place it between:
  - `Tensor`
  - `Waveform Analysis`
- Route it from `DENNIS/Views/DetailView.swift`.
- New files:
  - `DENNIS/Decoding/Decoding.swift`
  - `DENNIS/Decoding/DecodingInput.swift`
  - `DENNIS/Decoding/DecodingMetrics.swift`
  - `DENNIS/Views/DecodingView.swift`
  - `DENNISTests/DecodingTests.swift`

The implementation should follow the existing pattern used by Tensor and PLS:
a model/engine layer that is testable outside SwiftUI, plus a tab view that
gathers settings, launches analysis tasks, and visualizes results.

## Core Question

The tab should answer:

> Can distributed EEG/ERP patterns predict condition, group, or behavior labels
> above chance, and when/where does that information appear?

## Prediction Targets

Support user-selectable decoding targets.

### Initial Targets

- Condition decoding:
  - Predict condition/category from ERP pattern.
  - Natural first target for current DENNIS data.
  - Rows are subject-condition observations.
- Pairwise condition contrasts:
  - Example: `ba+` vs `da+`.
  - Example: congruent vs incongruent.
- Multiclass condition classification:
  - Predict among all selected categories.
- One-vs-rest decoding:
  - One condition/class against all others.

### Later Targets

- Between-subject group classification:
  - Predict factor levels such as age group, twin type, clinical/control.
- Train/test generalization by group:
  - Train on one age group, test on another.
- Continuous regression targets:
  - Age, behavioral scores, reaction time, clinical measures.

## Feature Spaces

Offer feature modes that map naturally onto EEG/ERP MVPA.

### Full Spatiotemporal ERP

Flatten selected `channels x time` samples into one feature vector per
observation.

Use this for:

- Whole-window condition decoding.
- Group classification from ERP morphology.
- Exportable classifier patterns.

Because this can produce many features relative to subjects, it should default
to regularized classifiers and optionally offer dimensionality reduction.

### Time-Resolved Decoding

Classify independently at each time sample using all channels.

Outputs:

- Accuracy-over-time curve.
- Balanced-accuracy-over-time curve.
- Optional p-value/effect-over-time curve.

Useful for:

- Discriminability onset.
- Peak latency of condition information.
- Comparing decoding to ERP components.

### Sliding-Window Decoding

Classify using all channels across small temporal windows.

Settings:

- Window width, e.g. 20 ms, 50 ms, 100 ms.
- Step size, e.g. one sample, 10 ms, 25 ms.
- Optional downsampling.

This is often more stable than single-sample decoding.

### ROI / Channel-Set Decoding

Allow decoding over:

- All channels.
- Selected channels.
- Named regional sets:
  - frontal
  - central
  - parietal
  - occipital
  - temporal/left/right if supported by layout metadata
- Custom channel lists.

### Waveform-Window Features

Reuse measurement windows from Waveform Analysis.

Examples:

- Mean amplitude per channel per window.
- Peak amplitude per channel per window.
- Adaptive mean per channel per window.

This creates interpretable low-dimensional features.

### PCA-Reduced Features

Offer optional PCA before classification.

Important rule:

- PCA must be fit only on each training fold, then applied to that fold's test
  data.

Possible settings:

- Fixed component count.
- Variance-retained threshold.
- Scree-based recommendation later.

### Tensor-Factor Features

Later, allow classification from Tensor/PARAFAC outputs:

- Subject loadings.
- Condition-scaled component scores.
- Reconstructed component amplitudes.
- Component-wise feature sets.

This would connect decoding to DENNIS's existing tensor analysis rather than
making the tab feel isolated.

### Time-Frequency Features

Later, reuse the existing time-frequency stack:

- Band power features.
- Time-frequency tiles.
- Evoked power from averaged ERP.
- Eventually single-trial power once epochs exist.

## Classifiers

Start with robust linear models that behave well with EEG/ERP data.

### MVP Classifiers

- Nearest centroid / correlation classifier:
  - Simple.
  - Transparent.
  - Good baseline.
- Shrinkage LDA:
  - Recommended default.
  - Strong fit for high-dimensional ERP data.
  - Stable with modest sample counts.

### Later Classifiers

- Logistic regression with L2 regularization.
- Linear SVM.
- Ridge regression classifier.
- Multiclass one-vs-rest wrappers where needed.

Avoid nonlinear models in the first pass. Most ERP datasets are small,
high-dimensional, and easy to overfit.

## Cross-Validation

Cross-validation needs to be subject-safe by default.

### Initial Schemes

- Leave-one-subject-out:
  - Best default for condition decoding across subjects.
  - Keeps each subject's observations out of training together.
- K-fold by subject:
  - Subject-safe folds.
  - More efficient than leave-one-subject-out for larger datasets.
- Stratified k-fold:
  - Useful for balanced class labels.
  - Must still avoid subject leakage when subject identity is present.

### Later Schemes

- Within-subject condition decoding:
  - Requires single-trial epochs.
- Train/test split by group:
  - Train on one group, test on another.
- Cross-condition generalization:
  - Train on condition set A, test on condition set B.
- Cross-time generalization:
  - Train at one time/window, test at another.

### Leakage Safeguards

All preprocessing must happen inside the training fold.

Fit on training only:

- Standardization.
- PCA/dimensionality reduction.
- Feature selection.
- Channel/window selection if data-driven.
- Any variance or covariance estimates.

Then apply the fitted transform to held-out test data.

Warn when:

- Class counts are very small.
- Classes are badly imbalanced.
- A fold lacks one or more classes.
- The selected validation scheme leaks subject identity.

## MVPA-Style Analyses

### Time-Resolved Decoding

Train/test at each time point or sliding window.

Primary output:

- Metric over time.

Interpretation:

- When condition information becomes discriminable.
- Whether decoding is transient or sustained.
- Whether decoding peaks align with ERP components.

### Temporal Generalization Matrix

Train at each time point/window and test at every other time point/window.

Primary output:

```text
train time x test time
```

Interpretation:

- Strong diagonal:
  - Moment-by-moment discriminability.
- Narrow diagonal:
  - Rapidly changing representation.
- Broad off-diagonal blocks:
  - Stable or sustained representation.
- Recurrent off-diagonal structure:
  - Re-emergence of similar patterns over time.

This should be a marquee feature after the MVP.

### Searchlight / Sensor-Neighborhood Decoding

Run decoding over local electrode neighborhoods.

Use `SensorLayout` to define neighborhoods when available.

Outputs:

- Topomap of accuracy or balanced accuracy.
- Time-specific topomaps.
- Optional animated time sweep later.

### Representational Similarity Approximation

Add RSA-adjacent analyses that do not require a classifier.

Compute condition-by-condition distance matrices from ERP patterns.

Distance options:

- Euclidean.
- Correlation distance.
- Cross-validated Mahalanobis later.

Views:

- Representational dissimilarity matrix for a selected time/window.
- RDM over time.
- Group comparison of RDMs.

### Pattern Interpretation

For linear classifiers, expose interpretable pattern views.

Possible views:

- Raw classifier weights.
- Haufe-transformed activation patterns.
- Topomap at selected time/window.
- Channel contribution ranking.
- Signed class-separation maps.

Important UI language:

- Classifier weights are not automatically neural activation patterns.
- If activation maps are shown, label them distinctly from raw weights.

## Statistics And Inference

Decoding needs inference, not only accuracy plots.

### Initial Statistics

- Empirical chance level:
  - 50% for balanced binary.
  - `1 / k` for balanced multiclass.
  - Majority-class baseline for imbalanced sets.
- Permutation testing:
  - Shuffle labels.
  - Rerun full cross-validation.
  - Compare observed metric to null distribution.
- Confidence intervals:
  - Bootstrap over subjects or folds.

### Later Statistics

- Cluster-based correction over time.
- Cluster-based correction over train-time x test-time matrices.
- Binomial test for simple binary settings.
- Effect sizes:
  - Accuracy minus chance.
  - Balanced accuracy minus chance.
  - Standardized decoding difference where appropriate.

## Metrics

Support:

- Accuracy.
- Balanced accuracy.
- AUC for binary classifiers.
- d-prime.
- F1.
- Precision.
- Recall.
- Per-class sensitivity/specificity.
- Confusion matrix.

Default display metric:

- Balanced accuracy.

Balanced accuracy is safer when category counts differ.

## UI Design

The tab should be an analysis workspace, not a landing page.

### Header

Show:

```text
Group · N subjects · K conditions · C channels · T samples
```

Also show data readiness:

- Loaded subjects.
- Shared conditions.
- Sampling rate.
- Time range.

### Main Controls

Controls should be compact and grouped.

Sections:

- Target:
  - condition
  - group factor later
  - custom contrast later
- Classes:
  - selectable conditions or levels
  - pairwise/multiclass toggle
- Features:
  - full ERP window
  - time-resolved
  - sliding window
  - waveform windows
  - PCA scores later
- Window:
  - pre ms
  - post ms
  - downsample
  - sliding width/step
- Channels:
  - all
  - ROI
  - custom
- Classifier:
  - shrinkage LDA default
  - nearest centroid
- Validation:
  - leave-one-subject-out default
  - subject k-fold
- Statistics:
  - permutations
  - bootstrap confidence interval
  - cluster correction later

### Results Views

Show:

- Decoding-over-time curve.
- Whole-window summary metric.
- Confusion matrix.
- Fold/prediction table.
- Temporal generalization heatmap later.
- Topomap/pattern map later.
- Export panel.

### Exports

Export:

- Per-fold predictions CSV.
- Metric-over-time CSV.
- Temporal generalization matrix CSV.
- Confusion matrix CSV.
- Classifier pattern maps.
- Analysis settings metadata.

Settings metadata should include:

- Group.
- Conditions/classes.
- Feature mode.
- Time window.
- Channel set.
- Classifier.
- Cross-validation scheme.
- Metric.
- Permutation settings.
- Software/app version later.

## Implementation Phases

### Phase 1: Tab Skeleton + Average-Based Decoding

Build:

- `AppMode.decoding`.
- `DecodingView(groupID:)`.
- `DecodingInput` from `EPTensor.snapshot`.
- Condition decoding with rows as subject-condition observations.
- Full ERP window features.
- Nearest centroid classifier.
- Shrinkage LDA classifier.
- Leave-one-subject-out validation.
- Accuracy, balanced accuracy, confusion matrix.
- Synthetic tests with separable ERP patterns.

This phase should produce a useful whole-window classifier before adding richer
visualizations.

### Phase 2: Time-Resolved Decoding

Build:

- Per-time-sample decoding.
- Sliding-window decoding.
- Decoding-over-time plot.
- Metric CSV export.
- Permutation testing over labels.

### Phase 3: Temporal Generalization

Build:

- Train at every time/window.
- Test at every time/window.
- Time x time heatmap.
- Matrix CSV export.
- Optional smoothing.
- Cluster summary later.

### Phase 4: Spatial / ROI Decoding

Build:

- Channel subset picker.
- Sensor-neighborhood searchlight.
- Topomap of decoding performance.
- Linear classifier pattern maps.

### Phase 5: Richer Targets

Build:

- Between-subject group classification.
- Train-on-group/test-on-group generalization.
- Pairwise batch decoding for all condition pairs.
- Multiclass one-vs-rest table.
- Regression target scaffolding.

### Phase 6: True Single-Trial MVPA

Extend importer and data model to preserve epochs or pseudo-trials.

Needed:

- Single-trial MFF epoch loading.
- Trial labels.
- Artifact/rejection metadata.
- Trial count summaries.
- Pseudo-trial averaging/binning.
- Within-subject cross-validation.
- Cross-subject generalization.
- Time-frequency single-trial decoding.

## Recommended MVP

The first complete version should include:

- Condition decoding.
- Selected group only.
- Shared conditions only.
- Full ERP time-window features.
- Time-resolved decoding if feasible in the same pass.
- Shrinkage LDA default.
- Nearest centroid baseline.
- Leave-one-subject-out validation.
- Balanced accuracy.
- Confusion matrix.
- Permutation p-value.
- Decoding curve visualization.
- CSV export.

This gives DENNIS a real MVPA-like workflow while staying honest about the
averaged-ERP limitation. The next marquee feature should be temporal
generalization.
