//
//  References.swift
//  DENNIS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The literature behind every statistical method DENNIS implements, in one
//  place so the code comments and the in-app help cite the same sources. Each
//  entry names what in DENNIS rests on it, because a reference list that does
//  not say what it is supporting is decoration.
//
//  These are the papers a methods section would cite for a given analysis. The
//  citation strings are surfaced verbatim in each mode's "References" popover
//  (Permutation Statistics, PCA, Tensor, PLS), grouped by what that mode needs.
//

import Foundation

nonisolated struct Reference: Sendable, Equatable, Identifiable, Hashable {
    let key: String
    /// Author-year form for inline mention, e.g. "Maris & Oostenveld (2007)".
    let short: String
    /// Full citation.
    let citation: String
    /// What in DENNIS this source supports.
    let supports: String

    var id: String { key }
}

nonisolated enum References {
    // MARK: - Cluster permutation: method

    static let marisOostenveld = Reference(
        key: "maris2007",
        short: "Maris & Oostenveld (2007)",
        citation: """
        Maris, E., & Oostenveld, R. (2007). Nonparametric statistical testing of \
        EEG- and MEG-data. Journal of Neuroscience Methods, 164(1), 177–190.
        """,
        supports: "The cluster-mass test itself: cluster-forming threshold, "
            + "spatiotemporal cluster growth, and the maximum-cluster-statistic "
            + "null that controls the family-wise error rate."
    )

    static let smithNichols = Reference(
        key: "smith2009",
        short: "Smith & Nichols (2009)",
        citation: """
        Smith, S. M., & Nichols, T. E. (2009). Threshold-free cluster enhancement: \
        Addressing problems of smoothing, threshold dependence and localisation in \
        cluster inference. NeuroImage, 44(1), 83–98.
        """,
        supports: "Threshold-free cluster enhancement, including the default "
            + "extent (E = 0.5) and height (H = 2) exponents."
    )

    static let coxETAC = Reference(
        key: "cox2019",
        short: "Cox (2019)",
        citation: """
        Cox, R. W. (2019). Equitable Thresholding and Clustering: A novel method \
        for functional magnetic resonance imaging clustering in AFNI. Brain \
        Connectivity, 9(7), 529–538.
        """,
        supports: "The ETAC strategy of balancing multiple cluster subtests on "
            + "a common false-positive scale and using their jointly calibrated "
            + "union to reduce dependence on one arbitrary forming threshold."
    )

    static let nicholsHolmes = Reference(
        key: "nichols2002",
        short: "Nichols & Holmes (2002)",
        citation: """
        Nichols, T. E., & Holmes, A. P. (2002). Nonparametric permutation tests for \
        functional neuroimaging: A primer with examples. Human Brain Mapping, 15(1), 1–25.
        """,
        supports: "The max-statistic permutation framework, and the sign-flipping "
            + "scheme used for within-subject designs."
    )

    static let groppe = Reference(
        key: "groppe2011",
        short: "Groppe, Urbach & Kutas (2011)",
        citation: """
        Groppe, D. M., Urbach, T. P., & Kutas, M. (2011). Mass univariate analysis of \
        event-related brain potentials/fields I: A critical tutorial review. \
        Psychophysiology, 48(12), 1711–1725.
        """,
        supports: "Practical guidance for mass-univariate ERP analysis: choosing a "
            + "time window and channel set before looking at the data."
    )

    // MARK: - Cluster permutation: interpretation

    static let sassenhagen = Reference(
        key: "sassenhagen2019",
        short: "Sassenhagen & Draschkow (2019)",
        citation: """
        Sassenhagen, J., & Draschkow, D. (2019). Cluster-based permutation tests of \
        MEG/EEG data do not establish significance of effect latency or location. \
        Psychophysiology, 56(6), e13335.
        """,
        supports: "The interpretation caveat shown with every result: a corrected "
            + "p-value licenses a claim about the cluster as a whole, not about "
            + "its onset, offset, or sensor extent."
    )

    // MARK: - Cluster permutation: exchangeability and p-values

    static let ernst = Reference(
        key: "ernst2004",
        short: "Ernst (2004)",
        citation: """
        Ernst, M. D. (2004). Permutation methods: A basis for exact inference. \
        Statistical Science, 19(4), 676–685.
        """,
        supports: "Systematic (exhaustive) enumeration and the exact p-value it "
            + "yields, used whenever the design admits few enough rearrangements."
    )

    static let phipsonSmyth = Reference(
        key: "phipson2010",
        short: "Phipson & Smyth (2010)",
        citation: """
        Phipson, B., & Smyth, G. K. (2010). Permutation p-values should never be zero: \
        Calculating exact p-values when permutations are randomly drawn. \
        Statistical Applications in Genetics and Molecular Biology, 9(1), Article 39.
        """,
        supports: "The (b + 1)/(m + 1) Monte-Carlo p-value, which keeps a sampled "
            + "test exact instead of reporting an impossible p = 0."
    )

    static let winkler = Reference(
        key: "winkler2014",
        short: "Winkler et al. (2014)",
        citation: """
        Winkler, A. M., Ridgway, G. R., Webster, M. A., Smith, S. M., & Nichols, T. E. \
        (2014). Permutation inference for the general linear model. NeuroImage, 92, 381–397.
        """,
        supports: "Which relabelings are exchangeable in a given design, and why "
            + "within-subject data must be permuted within subject rather than across."
    )

    static let andersonTerBraak = Reference(
        key: "anderson2003",
        short: "Anderson & ter Braak (2003)",
        citation: """
        Anderson, M. J., & ter Braak, C. J. F. (2003). Permutation tests for \
        multi-factorial analysis of variance. Journal of Statistical Computation and \
        Simulation, 73(2), 85–113.
        """,
        supports: "Why DENNIS offers an omnibus over cells plus difference-score "
            + "contrasts rather than a general factorial permutation scheme: there "
            + "is no single agreed exact test for interactions in a mixed design."
    )

    // MARK: - Cluster permutation: sensor neighborhoods

    static let fieldtrip = Reference(
        key: "oostenveld2011",
        short: "Oostenveld et al. (2011)",
        citation: """
        Oostenveld, R., Fries, P., Maris, E., & Schoffelen, J.-M. (2011). FieldTrip: \
        Open source software for advanced analysis of MEG, EEG, and invasive \
        electrophysiological data. Computational Intelligence and Neuroscience, 2011, 156869.
        """,
        supports: "The sensor-neighborhood conventions: a fixed radius in normalized "
            + "head-radius units, or K nearest sensors, symmetrized."
    )

    // MARK: - Cluster permutation: numerics

    static let lanczos = Reference(
        key: "lanczos1964",
        short: "Lanczos (1964)",
        citation: """
        Lanczos, C. (1964). A precision approximation of the gamma function. \
        SIAM Journal on Numerical Analysis, Series B, 1, 86–96.
        """,
        supports: "The log-gamma approximation underlying the t and F tail "
            + "probabilities, so a threshold can be entered as a p-value."
    )

    static let lentz = Reference(
        key: "lentz1976",
        short: "Lentz (1976)",
        citation: """
        Lentz, W. J. (1976). Generating Bessel functions in Mie scattering calculations \
        using continued fractions. Applied Optics, 15(3), 668–671.
        """,
        supports: "The continued-fraction evaluation method used for the regularized "
            + "incomplete beta function (DLMF §8.17)."
    )

    // MARK: - PCA: ERP PCA Toolkit

    static let dien2010 = Reference(
        key: "dien2010",
        short: "Dien (2010)",
        citation: """
        Dien, J. (2010). The ERP PCA Toolkit: An open source program for advanced \
        statistical analysis of event-related potential data. Journal of Neuroscience \
        Methods, 187(1), 138–145.
        """,
        supports: "The single- and two-step (temporal-then-spatial) PCA workflow "
            + "DENNIS's PCA mode ports, including the COV/COR/SCP relation-matrix "
            + "choice and Kaiser loading normalization."
    )

    static let dien2005 = Reference(
        key: "dien2005",
        short: "Dien, Beal & Berg (2005)",
        citation: """
        Dien, J., Beal, D. J., & Berg, P. (2005). Optimizing principal components \
        analysis of event-related potentials: Matrix type, factor loading weighting, \
        extraction, and rotations. Clinical Neurophysiology, 116(8), 1808–1825.
        """,
        supports: "The recommendation to run PCA temporally first and spatially "
            + "second, and to prefer Promax over Varimax for ERP factor structure."
    )

    static let kaiser1958 = Reference(
        key: "kaiser1958",
        short: "Kaiser (1958)",
        citation: """
        Kaiser, H. F. (1958). The varimax criterion for analytic rotation in factor \
        analysis. Psychometrika, 23(3), 187–200.
        """,
        supports: "Varimax rotation, including the Kaiser normalization applied "
            + "before rotating."
    )

    static let hendricksonWhite1964 = Reference(
        key: "hendrickson1964",
        short: "Hendrickson & White (1964)",
        citation: """
        Hendrickson, A. E., & White, P. O. (1964). Promax: A quick method for \
        rotation to oblique simple structure. British Journal of Statistical \
        Psychology, 17(1), 65–70.
        """,
        supports: "Promax oblique rotation, run after an initial Varimax solution."
    )

    static let horn1965 = Reference(
        key: "horn1965",
        short: "Horn (1965)",
        citation: """
        Horn, J. L. (1965). A rationale and test for the number of factors in factor \
        analysis. Psychometrika, 30(2), 179–185.
        """,
        supports: "Parallel analysis: comparing the data's eigenvalue scree against "
            + "the scree of random data of the same shape to choose how many "
            + "factors to retain."
    )

    static let bellSejnowski1995 = Reference(
        key: "bell1995",
        short: "Bell & Sejnowski (1995)",
        citation: """
        Bell, A. J., & Sejnowski, T. J. (1995). An information-maximization approach \
        to blind separation and blind deconvolution. Neural Computation, 7(6), 1129–1159.
        """,
        supports: "Infomax ICA, offered as an oblique rotation alternative to "
            + "Varimax/Promax in the PCA workflow."
    )

    static let gramfort2013 = Reference(
        key: "gramfort2013",
        short: "Gramfort et al. (2013)",
        citation: """
        Gramfort, A., Luessi, M., Larson, E., Engemann, D. A., Strohmeier, D., \
        Brodbeck, C., Goj, R., Jas, M., Brooks, T., Parkkonen, L., & Hämäläinen, M. \
        (2013). MEG and EEG data analysis with MNE-Python. Frontiers in Neuroscience, \
        7, Article 267.
        """,
        supports: "The Infomax implementation, ported from MNE-Python's "
            + "`preprocessing.infomax_`, itself a port of the EEGLAB `runica` infomax."
    )

    // MARK: - PARAFAC / multiway

    static let harshman1970 = Reference(
        key: "harshman1970",
        short: "Harshman (1970)",
        citation: """
        Harshman, R. A. (1970). Foundations of the PARAFAC procedure: Models and \
        conditions for an "explanatory" multi-modal factor analysis. UCLA Working \
        Papers in Phonetics, 16, 1–84.
        """,
        supports: "The PARAFAC / CANDECOMP model DENNIS's tensor mode fits: a "
            + "rank-R sum of outer products, one vector per mode, essentially "
            + "unique without rotation."
    )

    static let kolda2009 = Reference(
        key: "kolda2009",
        short: "Kolda & Bader (2009)",
        citation: """
        Kolda, T. G., & Bader, B. W. (2009). Tensor decompositions and applications. \
        SIAM Review, 51(3), 455–500.
        """,
        supports: "The alternating-least-squares algorithm DENNIS uses to fit "
            + "PARAFAC: for each mode, the Khatri-Rao/Hadamard update this "
            + "implementation follows directly."
    )

    static let harshman1972 = Reference(
        key: "harshman1972",
        short: "Harshman (1972)",
        citation: """
        Harshman, R. A. (1972). PARAFAC2: Mathematical and technical notes. \
        UCLA Working Papers in Phonetics, 22, 30–47.
        """,
        supports: "The PARAFAC2 model: one mode allowed to vary in shape by slice, "
            + "used here to model ERP latency/shape variation across subjects."
    )

    static let kiers1999 = Reference(
        key: "kiers1999",
        short: "Kiers, ten Berge & Bro (1999)",
        citation: """
        Kiers, H. A. L., ten Berge, J. M. F., & Bro, R. (1999). PARAFAC2—Part I. A \
        direct fitting algorithm for the PARAFAC2 model. Journal of Chemometrics, \
        13(3–4), 275–294.
        """,
        supports: "The direct-fitting PARAFAC2 algorithm — orthonormal per-slice "
            + "loadings via a shared basis — that DENNIS's `PARAFAC2.swift` implements."
    )

    // MARK: - PLS

    static let mcintoshLobaugh2004 = Reference(
        key: "mcintosh2004",
        short: "McIntosh & Lobaugh (2004)",
        citation: """
        McIntosh, A. R., & Lobaugh, N. J. (2004). Partial least squares analysis of \
        neuroimaging data: Applications and advances. NeuroImage, 23, S250–S263.
        """,
        supports: "Mean-centered (task) PLS: the SVD of the condition-mean by "
            + "brain-data cross-covariance, and permutation testing of its "
            + "singular values."
    )

    static let krishnan2011 = Reference(
        key: "krishnan2011",
        short: "Krishnan et al. (2011)",
        citation: """
        Krishnan, A., Williams, L. J., McIntosh, A. R., & Abdi, H. (2011). Partial \
        Least Squares (PLS) methods for neuroimaging: A tutorial and review. \
        NeuroImage, 56(2), 455–475.
        """,
        supports: "Bootstrap ratios on the brain saliences, as the reliability "
            + "measure for PLS's spatiotemporal pattern."
    )

    // MARK: - Groupings

    /// Everything, in the order a combined methods section would introduce it.
    static let all: [Reference] = [
        marisOostenveld, smithNichols, coxETAC, nicholsHolmes, groppe,
        sassenhagen,
        ernst, phipsonSmyth, winkler, andersonTerBraak,
        fieldtrip,
        lanczos, lentz,
        dien2010, dien2005, kaiser1958, hendricksonWhite1964, horn1965,
        bellSejnowski1995, gramfort2013,
        harshman1970, kolda2009, harshman1972, kiers1999,
        mcintoshLobaugh2004, krishnan2011,
    ]

    // Cluster permutation (Permutation Statistics pane).
    static let forClusterMethod: [Reference] = [marisOostenveld, smithNichols, coxETAC, nicholsHolmes]
    static let forClusterDesign: [Reference] = [winkler, andersonTerBraak, nicholsHolmes]
    static let forClusterThreshold: [Reference] = [marisOostenveld, groppe]
    static let forClusterInference: [Reference] = [marisOostenveld, smithNichols, coxETAC]
    static let forClusterAdjacency: [Reference] = [fieldtrip, marisOostenveld]
    static let forClusterPermutationCount: [Reference] = [ernst, phipsonSmyth]
    static let forClusterInterpretation: [Reference] = [sassenhagen, marisOostenveld]
    static let forCluster: [Reference] = [
        marisOostenveld, smithNichols, coxETAC, nicholsHolmes, groppe, sassenhagen,
        ernst, phipsonSmyth, winkler, andersonTerBraak, fieldtrip, lanczos, lentz,
    ]

    // PCA (PCA pane).
    static let forPCAMethod: [Reference] = [dien2010, dien2005]
    static let forRotation: [Reference] = [kaiser1958, hendricksonWhite1964, dien2005]
    static let forInfomax: [Reference] = [bellSejnowski1995, gramfort2013]
    static let forScree: [Reference] = [horn1965]
    static let forPCA: [Reference] = [
        dien2010, dien2005, kaiser1958, hendricksonWhite1964, horn1965,
        bellSejnowski1995, gramfort2013,
    ]

    // Tensor / PARAFAC (Tensor pane).
    static let forPARAFAC: [Reference] = [harshman1970, kolda2009]
    static let forPARAFAC2: [Reference] = [harshman1972, kiers1999, harshman1970]
    static let forTensor: [Reference] = [harshman1970, kolda2009, harshman1972, kiers1999]

    // PLS (PLS pane).
    static let forPLS: [Reference] = [mcintoshLobaugh2004, krishnan2011]

    /// Renders citations for a help popover, one per paragraph.
    static func text(_ references: [Reference]) -> String {
        references.map(\.citation).joined(separator: "\n\n")
    }

    /// Author-year list for an inline mention, e.g. "See Maris & Oostenveld
    /// (2007); Smith & Nichols (2009)."
    static func shortList(_ references: [Reference]) -> String {
        references.map(\.short).joined(separator: "; ")
    }
}
