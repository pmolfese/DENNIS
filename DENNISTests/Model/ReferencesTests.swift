//
//  ReferencesTests.swift
//  DENNISTests
//
//  The citation list is surfaced verbatim across several panes' UI and echoed
//  in the source headers, so it is worth a few assertions that it stays
//  coherent as new methods and groupings get added.
//

import Foundation
import Testing
@testable import DENNIS

struct ReferencesTests {
    @Test func everyReferenceIsCompleteAndUniquelyKeyed() {
        let all = References.all
        #expect(all.count >= 20)
        #expect(Set(all.map(\.key)).count == all.count)
        for reference in all {
            #expect(!reference.short.isEmpty)
            #expect(!reference.citation.isEmpty)
            // Every entry has to say what in DENNIS rests on it; a bare list is
            // decoration rather than documentation.
            #expect(!reference.supports.isEmpty)
            // Citations carry a year, so they can actually be located.
            let hasYear = reference.citation.contains("(19") || reference.citation.contains("(20")
            #expect(hasYear)
        }
    }

    @Test func everyTopicGroupingDrawsOnlyFromTheMasterList() {
        let keys = Set(References.all.map(\.key))
        let groupings: [(String, [Reference])] = [
            ("clusterMethod", References.forClusterMethod),
            ("clusterDesign", References.forClusterDesign),
            ("clusterThreshold", References.forClusterThreshold),
            ("clusterInference", References.forClusterInference),
            ("clusterAdjacency", References.forClusterAdjacency),
            ("clusterPermutationCount", References.forClusterPermutationCount),
            ("clusterInterpretation", References.forClusterInterpretation),
            ("cluster", References.forCluster),
            ("pcaMethod", References.forPCAMethod),
            ("rotation", References.forRotation),
            ("infomax", References.forInfomax),
            ("scree", References.forScree),
            ("pca", References.forPCA),
            ("parafac", References.forPARAFAC),
            ("parafac2", References.forPARAFAC2),
            ("tensor", References.forTensor),
            ("pls", References.forPLS),
        ]
        for (name, grouping) in groupings {
            #expect(!grouping.isEmpty, "\(name) cites nothing")
            for reference in grouping {
                #expect(keys.contains(reference.key), "\(name) cites unlisted \(reference.key)")
            }
        }
    }

    @Test func helpTextAppendsTheSourcesItRestsOn() {
        // Every help popover ends with the author-year list, so a user
        // configuring a run can cite what they just read.
        #expect(PermutationStatisticsView.methodHelp.contains("Maris & Oostenveld (2007)"))
        #expect(PermutationStatisticsView.interpretationHelp.contains("Sassenhagen & Draschkow (2019)"))
        #expect(PermutationStatisticsView.permutationsHelp.contains("Ernst (2004)"))
        #expect(PermutationStatisticsView.neighborsHelp.contains("Oostenveld et al. (2011)"))
        #expect(PermutationStatisticsView.measureHelp.contains("Anderson & ter Braak (2003)"))
    }

    @Test func shortListJoinsAuthorYearForms() {
        let text = References.shortList([
            References.marisOostenveld,
            References.smithNichols,
        ])
        #expect(text == "Maris & Oostenveld (2007); Smith & Nichols (2009)")
    }

    // MARK: - New domains

    @Test func pcaGroupingCitesDienForTheWorkflow() {
        #expect(References.forPCAMethod.contains(References.dien2010))
        #expect(References.forRotation.contains(References.kaiser1958))
        #expect(References.forRotation.contains(References.hendricksonWhite1964))
        #expect(References.forScree.contains(References.horn1965))
    }

    @Test func tensorGroupingCitesHarshmanForBothParafacVariants() {
        #expect(References.forPARAFAC.contains(References.harshman1970))
        #expect(References.forPARAFAC2.contains(References.harshman1972))
        #expect(References.forPARAFAC2.contains(References.kiers1999))
    }

    @Test func plsGroupingCitesMcIntoshAndLobaugh() {
        #expect(References.forPLS.contains(References.mcintoshLobaugh2004))
    }
}
