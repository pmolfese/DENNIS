# Cluster-Based Permutation Testing for DENNIS

**Audience:** an agent session picking this up cold, with no memory of the EVA work.
**Reference implementation:** `~/Documents/Programming/EVA/EVA/Trials/Cluster*.swift` (branch `aug10`), plus its tests in `EVA/EVATests/Trials/Cluster*Tests.swift`. Read those files before writing anything here — this document tells you *what to change*, not what the algorithms are.

---

## 1. Why this belongs in DENNIS more than it belonged in EVA

The EVA implementation treats a **single trial** as the unit of observation. That is defensible for single-subject work, but Maris & Oostenveld (2007) is written for designs where the exchangeable unit is the **subject**, and almost every published EEG cluster test is a group test.

DENNIS already has exactly that structure:

- `Dataset` (in `DENNIS/Model/Study.swift`) = **one subject**, one averaged `.mff`.
- `Condition` = one within-subject cell (an MFF `<cat>`), holding `samples: [[Float]]?` as `channels × samples`, plus `baselineSamples` and `sampleCount`.
- `Study.factors` = **between-subject** factors, with each subject's levels in `Dataset.levels` (index-aligned).
- `Study.conditionFactors` = **within-subject** factors, with each condition's levels in `Condition.levels` (index-aligned).
- `Study.datasets(inGroupID:)` and `GroupNode` already slice subjects by factor-level combinations.

So the port is not a translation exercise — it is the version of this feature that actually matches the statistics. Budget your effort accordingly: the *design layer* is where the new work is, and the numerical core is a near-verbatim copy.

---

## 2. What to copy verbatim

These four files from `EVA/EVA/Trials/` are domain-agnostic. Copy them into a new `DENNIS/Stats/` group, changing only the header comments and the small items in §5.

| EVA file | Purpose | Change needed |
|---|---|---|
| `ClusterStatisticsDistributions.swift` | t and F tails + inverses, via the DLMF 8.17.22 incomplete-beta continued fraction and Lanczos log-gamma | None |
| `ClusterFormation.swift` | `ClusterGrid` (CSR channel × time lattice), connected components, union-find TFCE, `ClusterCorrection` | None |
| `ClusterSpatialAdjacency.swift` | distance / K-nearest / temporal-only neighbor graphs, plus `summarize` and `suggestedDistance` | None — DENNIS's `SensorPosition` (`channelIndex`, `x`, `y`) is structurally identical to EVA's |
| `ClusterPermutationAnalyzer.swift` / `ClusterPermutationFAnalyzer.swift` | the t and F analyzers | Extend, don't rewrite — see §4 |

**Do not re-derive the TFCE integration.** It is a single descending union-find sweep, not the textbook per-threshold re-run, and it is `O(n log n)` rather than `O(n × steps)`. There is a subtle correctness trap in it that cost a debugging cycle in EVA: when component *c* is absorbed into component *p*, `c`'s members must inherit only the charges `p` accrues **after** the merge, never the ones `p` accrued while `c` was still separate. The shipped code snapshots `pending[root]` at merge time into `parentChargeAtMerge` and subtracts it during the downward pass. Port that logic exactly, and port `ClusterFormationTests.tfceMatchesTheNaiveIntegral*` with it — those tests compare against a deliberately naive reference implementation of the same integral and are what caught the bug.

---

## 3. The design layer — this is the actual work

EVA offers two designs (independent trials, paired trials). DENNIS needs a proper design taxonomy because it has both a within- and a between-subject factor structure. Build this as a new type, roughly:

```swift
nonisolated enum ClusterDesign: Sendable, Equatable {
    /// Two within-subject conditions, all subjects contribute both.
    /// Paired t on differences; permutation = per-subject sign flip.
    case withinPairedT(conditionA: String, conditionB: String)

    /// k >= 3 within-subject conditions, all subjects contribute all.
    /// Repeated-measures F; permutation = relabel conditions within subject.
    case withinRepeatedF(conditions: [String])

    /// One condition (or a within-subject contrast, see below), compared across
    /// two between-subject groups. Independent t; permutation = shuffle group
    /// labels across subjects.
    case betweenT(measure: SubjectMeasure, groupA: String, groupB: String)

    /// One measure across k >= 3 between-subject groups. One-way F.
    case betweenF(measure: SubjectMeasure, groups: [String])

    /// The interaction: the within-subject difference score compared between
    /// groups. This is a `betweenT`/`betweenF` on a difference measure and needs
    /// no new statistic — only a different `SubjectMeasure`.
    case mixedInteraction(measure: SubjectMeasure, groups: [String])
}

/// What one subject contributes: either a single condition, or a contrast
/// collapsed to one channels x samples matrix before the test runs.
nonisolated enum SubjectMeasure: Sendable, Equatable {
    case condition(String)
    case difference(String, String)          // A - B
    case mean([String])                      // average over conditions
}
```

**The key simplification to hold onto:** every between-subject and mixed design reduces to *one matrix per subject*, then an independent-samples test. Every within-subject design reduces to *k matrices per subject*, then a paired/RM test. You do not need new statistics for the mixed case — you need `SubjectMeasure` to collapse the within-subject dimension first. Resist the urge to write a general factorial ANOVA; the omnibus F plus difference-score contrasts covers the designs DENNIS's data model can express, and a full mixed-model permutation scheme has non-obvious exchangeability problems that are out of scope.

Group identity comes from `Study` — reuse `datasets(inGroupID:)` / `GroupNode` rather than re-parsing `Dataset.levels`.

---

## 4. Analyzer changes

The EVA analyzers already carry `Design.independent` / `.repeatedMeasures`, `ClusterFormingThreshold.statistic|.probability`, and `ClusterInferenceMode.clusterMass|.tfce`. Keep all of that. Two things need attention:

### 4.1 Exhaustive permutation — do this, it matters here

EVA punted on this and it was defensible at hundreds of trials. **At group N it is not.** With 12 subjects a paired design has only 2¹² = 4096 distinct sign flips; requesting 10,000 permutations resamples a saturated null and the true p-value floor is 1/4097, not 1/10001. At N = 8 it is 1/257. Reporting "p < .001" from a design that cannot produce a p below .004 is wrong.

Implement:

- `rearrangementCount(design:) -> Int?` — 2^N for paired sign flips, C(N, n_A) for a two-group independent test, the multinomial for k groups, (k!)^N for within-subject RM. Return `nil` when it overflows a sensible cap.
- When that count is ≤ the requested permutation count, **enumerate systematically instead of sampling**. For sign flips this is a bitmask loop and is trivial; for the others, enumerate combinations.
- When enumerating exhaustively the observed arrangement is already in the null, so the p-value is `#{null ≥ observed} / count` — **not** the `(exceedances + 1)/(n + 1)` Monte-Carlo form. Get this branch right and test it.
- Surface the count in the UI: "4096 exhaustive rearrangements (complete null)" vs "10,000 of 3.2e18 sampled".

### 4.2 Data preparation

DENNIS stores `[[Float]]` as `channels × samples`. The analyzers want one flattened **channel-major** `[Double]` per unit: channel 0's samples, then channel 1's, and so on. Write a `ClusterStatisticsRunner` equivalent (model it on `EVA/Trials/ClusterStatisticsRunner.swift`) that handles:

- **Dimension mismatch.** `GrandAverage.compute` silently skips subjects whose `channelCount`/`sampleCount` differ from the first. A cluster test must **not** silently skip — it must refuse and name the offending subjects, because a dropped subject changes the design.
- **Missing conditions.** A subject lacking one of the selected conditions cannot contribute to a within-subject design. Exclude it and report exactly which subjects were excluded and why; never pad with zeros.
- **Time window.** Convert ms to samples using `Condition.baselineSamples` as the stimulus-onset index and `Dataset.samplingRate`. Verify every contributing subject shares the same `baselineSamples` and `samplingRate` — refuse with a clear message if not.
- **Sample stride.** Keep EVA's explicit stride control. It changes the temporal lattice clusters form on, not merely plot resolution, so it must stay visible rather than becoming an internal optimization.
- **Channel selection.** Restrict to channels present in `sensorLayout`. DENNIS has no bad-channel concept at this level; do not invent one.

---

## 5. DENNIS-specific porting details

These will each cost you ten minutes if you don't know them up front.

1. **`SplitMix64` needs a conformance.** DENNIS's PRNG lives in `DENNIS/PCA/Rotations.swift` and is byte-for-byte the same algorithm as EVA's `SeededGenerator`, but it does **not** declare `: RandomNumberGenerator`. Add the conformance (the `next() -> UInt64` requirement is already satisfied) so `Int.random(in:using:)` and `Bool.random(using:)` work in the shuffle helpers. Do not add a second PRNG.

2. **`WorkerPool.concurrentPerform`** in `DENNIS/PCA/PCASupport.swift` replaces EVA's `evaConcurrentPerform`, and `WorkerPool.maxWorkers` replaces `evaMaxWorkers`. Note the different signature — `WorkerPool` uses a lock-and-counter work queue rather than EVA's striping, which is fine, but **seed every permutation by index before the parallel fan-out** exactly as EVA does. Determinism must not depend on thread scheduling.

3. **Name collision on "cluster."** `DENNIS/Viz/ClusterERPView.swift` already uses "cluster" to mean *a set of channels sharing a PCA spatial loading sign*, and defines `ClusterSubject`. That is a completely different concept from a spatiotemporal statistical cluster. Namespace the new types (`SpatiotemporalCluster`, `ClusterGrid`, `ClusterStatistics*` — the EVA names are already distinct enough) and **do not** rename or reuse anything in `ClusterERPView.swift`. Consider a short comment there pointing at the distinction.

4. **`SensorLayout` is shared source with EVA.** Both projects carry a copy (this is recorded in project memory, including a y-flip bug that was fixed in both). If you find yourself needing to change `SensorLayout` or `TopomapView` to support this feature, **fix both projects** or you will reintroduce a divergence. `ClusterSpatialAdjacency` was deliberately written to need no layout changes at all.

5. **`TopomapView` needs the same two additions EVA made.** Check whether DENNIS's copy already has them: a `highlightedChannels: Set<Int>` parameter (draws a ring on cluster-member sensors) and `usesPositiveSequentialScale: Bool` (0→max colorbar for non-negative F, instead of the diverging ±max). If not, port both — they default to `[]`/`false` and are non-breaking. Also make the hover readout use `unitLabel` rather than a hardcoded "µV", since these maps show t and F.

6. **Xcode project needs no edit.** DENNIS uses `PBXFileSystemSynchronizedRootGroup` (confirmed, 5 of them). Adding files to `DENNIS/Stats/` and `DENNISTests/Stats/` on disk is sufficient.

7. **Tests use swift-testing**, not XCTest (`import Testing`, `@Test`, `#expect`, `#require`). Two known traps: `#expect(x.allSatisfy(\.isEmpty))` fails to compile inside the macro — use a closure; and `#expect` with a `mutating` call on a local needs the call hoisted out first.

---

## 6. Where it goes in the UI

`DENNIS/Views/StatisticalAnalysisView.swift` is currently a stub whose own header says "In-app analyses will grow here." It is the right home, but note it currently gates on `store.dual` (a PCA result) — **cluster permutation must not require a PCA**, so restructure that gate rather than nesting inside it.

Model the pane on `EVA/Trials/ClusterStatisticsViews.swift`. Carry over these UI decisions, which were arrived at deliberately:

- **Threshold entered as p by default**, with a ⇄ toggle to raw statistic, and a live readout of the resolved critical value (`0.05 = |t| 2.04`) computed from the degrees of freedom the *current* design will produce. A fixed |t| means a different p at every N, so it is only comparable within one analysis.
- **Live adjacency readout** — "3.8 neighbors per sensor" — that turns orange with an explanation when the graph is fragmented (isolated sensors) or over-connected (mean > 12, where distinct effects merge into one blob).
- **Default neighbor radius derived from the montage**, via `ClusterSpatialAdjacency.suggestedDistance` (1.7× median nearest-neighbor spacing), not a constant.
- **A one-line methods summary in the results header**: `4096 exhaustive rearrangements · |t| ≥ 2.20 (p .050) · neighbors < 0.25 r (3.8 mean) · df=11`. Someone should be able to write a methods section from that line.
- **The interpretation caveat**, verbatim: corrected p-values apply to whole clusters; member sensors and time samples are not independently significant and are not precise spatial or temporal boundaries. Under TFCE, say instead that correction is point-wise and the displayed groupings are for readability.

For results display, DENNIS should show, per surviving cluster: the condition/group ERP traces averaged over the cluster's sensors with across-**subject** standard error (`ClusterStatisticsRunner.waveformSummary` ports directly, but the SEM is now across subjects, which is the meaningful one); the statistic topography with cluster sensors ringed; and the channel × time statistic heatmap.

---

## 7. Testing bar

Match what EVA ships (54 cases). Non-negotiable:

- **Distributions vs. R.** `qt`/`qf`/`pt`/`pf` reference values to 1e-6. EVA's `ClusterStatisticsDistributionsTests` ports as-is.
- **TFCE vs. a naive reference implementation** of the same integral, over randomized fields, signed and non-negative, to 1e-9. Port `ClusterFormationTests`.
- **Hand-calculated statistics.** A paired t and a repeated-measures F worked out by hand in the test comment. Show the arithmetic — both of EVA's hand calculations were wrong on the first pass and the comment is what made that obvious.
- **Determinism.** Same seed, two runs, `#expect(first == second)`, for every design and both inference modes.
- **A design that only the right test can find.** EVA's version: 20 units with large idiosyncratic offsets and a small consistent effect, where the paired design recovers it at p < .05 and the independent design finds nothing. Write the DENNIS analogue with subjects, and add the mirror case for the between-subject design.
- **Exhaustive-vs-Monte-Carlo agreement.** With N small enough to enumerate, a Monte-Carlo run with many permutations must approach the exhaustive p. And assert the p-value floor is `1/count` under enumeration, not `1/(n+1)`.
- **Refusals.** Dimension mismatch, missing condition, unbalanced units, single-subject group — each must produce a specific message, not a generic failure.

---

## 8. Explicit non-goals

Do not build these unless asked:

- A general factorial mixed-model permutation scheme. Exchangeability under a mixed model is genuinely contested; the omnibus F plus difference-score contrasts is the defensible scope.
- Post-hoc pairwise contrasts computed automatically after a significant omnibus F. Offer the two-condition test as a separate run the user chooses.
- Cluster-based inference on the PCA factor scores. Tempting given DENNIS's focus, but the channel × time lattice is what makes spatial adjacency meaningful; factor space has no such topology.
- Any change to `GrandAverage`, `WaveformAnalysis`, or the PCA path. This feature reads the same `Condition.samples` they do and writes nothing back.
