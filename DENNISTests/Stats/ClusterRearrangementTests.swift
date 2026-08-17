//
//  ClusterRearrangementTests.swift
//  DENNISTests
//
//  Counting and enumerating the rearrangements each design admits. This is the
//  part that matters at group N: with 12 subjects a paired design has only 4096
//  distinct sign flips, so a "10,000-permutation" run is resampling a saturated
//  null and the true p floor is 1/4096, not 1/10001.
//

import Foundation
import Testing
@testable import DENNIS

struct ClusterRearrangementTests {
    // MARK: - Counting

    @Test func signFlipCountIsTwoToTheSubjectCount() {
        #expect(ClusterRearrangements.rearrangementCount(.signFlip(unitCount: 8)) == 256)
        #expect(ClusterRearrangements.rearrangementCount(.signFlip(unitCount: 12)) == 4_096)
        #expect(ClusterRearrangements.rearrangementCount(.signFlip(unitCount: 64)) == nil)
    }

    @Test func groupLabelCountIsTheMultinomial() {
        // C(10, 4) = 210.
        #expect(ClusterRearrangements.rearrangementCount(.groupLabels(sizes: [4, 6])) == 210)
        // 9! / (3! 3! 3!) = 1680.
        #expect(ClusterRearrangements.rearrangementCount(.groupLabels(sizes: [3, 3, 3])) == 1_680)
        // Astronomical but still exact within Int for a modest study.
        #expect(ClusterRearrangements.rearrangementCount(.groupLabels(sizes: [20, 20])) == 137_846_528_820)
    }

    @Test func withinUnitRelabelCountIsFactorialToTheSubjectCount() {
        // (3!)^4 = 1296.
        #expect(ClusterRearrangements.rearrangementCount(
            .withinUnitRelabel(conditionCount: 3, unitCount: 4)
        ) == 1_296)
        // (3!)^30 overflows Int64 and must be reported as unknown, not wrong.
        #expect(ClusterRearrangements.rearrangementCount(
            .withinUnitRelabel(conditionCount: 3, unitCount: 30)
        ) == nil)
    }

    @Test func approximateCountSurvivesOverflow() {
        let approximate = ClusterRearrangements.approximateRearrangementCount(
            .withinUnitRelabel(conditionCount: 3, unitCount: 30)
        )
        // 6^30 = 2.2107e23.
        #expect(abs(approximate / 2.210_739e23 - 1) < 1e-4)
    }

    // MARK: - Enumeration

    @Test func signFlipEnumerationIsCompleteAndStartsFromTheIdentity() {
        let all = ClusterRearrangements.enumerate(.signFlip(unitCount: 4))
        #expect(all.count == 16)
        #expect(Set(all.map { $0.description }).count == 16)
        // Index 0 is "no subject flipped" — the observed data itself.
        #expect(all[0] == [0, 0, 0, 0])
        #expect(all.allSatisfy { $0.allSatisfy { bit in bit == 0 || bit == 1 } })
    }

    @Test func groupAssignmentEnumerationIsCompleteAndStartsFromTheObservedSplit() {
        let all = ClusterRearrangements.groupAssignments(sizes: [2, 3])
        #expect(all.count == 10)
        #expect(Set(all.map { $0.description }).count == 10)
        // Subjects are laid out group by group, so the first assignment is the
        // one the data already has.
        #expect(all[0] == [0, 0, 1, 1, 1])
        #expect(all.allSatisfy { $0.filter { $0 == 0 }.count == 2 })
        #expect(all.allSatisfy { $0.filter { $0 == 1 }.count == 3 })

        let threeWay = ClusterRearrangements.groupAssignments(sizes: [2, 2, 2])
        #expect(threeWay.count == 90)
        #expect(threeWay[0] == [0, 0, 1, 1, 2, 2])
    }

    @Test func conditionRelabelEnumerationIsCompleteAndStartsFromTheIdentity() {
        let all = ClusterRearrangements.enumerate(.withinUnitRelabel(conditionCount: 3, unitCount: 2))
        #expect(all.count == 36)
        #expect(Set(all.map { $0.description }).count == 36)
        #expect(all[0] == [0, 0])
        // Permutation 0 of three conditions is the identity, which is what makes
        // arrangement 0 the observed data.
        #expect(ClusterRearrangements.permutations(ofCount: 3)[0] == [0, 1, 2])
        #expect(ClusterRearrangements.permutations(ofCount: 3).count == 6)
        #expect(Set(ClusterRearrangements.permutations(ofCount: 4).map { $0.description }).count == 24)
    }

    // MARK: - Planning

    @Test func planEnumeratesWhenTheNullIsSmallerThanTheRequest() {
        let plan = ClusterRearrangements.plan(.signFlip(unitCount: 8), requestedCount: 10_000)
        #expect(plan.isExhaustive)
        #expect(plan.count == 256)
        #expect(plan.arrangements?.count == 256)
        // The floor a 10,000-permutation run *appears* to promise is .0001; the
        // design cannot actually produce anything below 1/256 = .0039.
        #expect(abs(plan.pValueFloor - 1.0 / 256) < 1e-12)
        #expect(plan.summary.contains("complete null"))
    }

    @Test func planSamplesWhenTheNullIsLargerThanTheRequest() {
        let plan = ClusterRearrangements.plan(.signFlip(unitCount: 30), requestedCount: 1_000)
        #expect(!plan.isExhaustive)
        #expect(plan.count == 1_000)
        #expect(plan.arrangements == nil)
        #expect(abs(plan.pValueFloor - 1.0 / 1_001) < 1e-12)
        #expect(plan.summary.contains("sampled"))
    }

    @Test func planFallsBackToSamplingWhenTheExactCountOverflows() {
        let plan = ClusterRearrangements.plan(
            .withinUnitRelabel(conditionCount: 4, unitCount: 40),
            requestedCount: 500
        )
        #expect(!plan.isExhaustive)
        #expect(plan.totalCount == nil)
        #expect(plan.approximateTotal.isFinite)
        #expect(plan.count == 500)
    }

    @Test func planRefusesToMaterializeMoreThanTheCap() {
        // 2^18 = 262,144 is below the requested count but above the cap, so the
        // run samples rather than materializing a quarter-million arrangements.
        let plan = ClusterRearrangements.plan(
            .signFlip(unitCount: 18),
            requestedCount: ClusterRearrangements.enumerationCap + 100_000
        )
        #expect(!plan.isExhaustive)
        #expect(plan.totalCount == 262_144)
        #expect(plan.arrangements == nil)
    }

    // MARK: - Counting helpers

    @Test func binomialAndMultinomialAgreeWithClosedForms() {
        #expect(ClusterRearrangements.binomial(10, 0) == 1)
        #expect(ClusterRearrangements.binomial(10, 10) == 1)
        #expect(ClusterRearrangements.binomial(10, 3) == 120)
        #expect(ClusterRearrangements.binomial(52, 5) == 2_598_960)
        #expect(ClusterRearrangements.multinomial([1, 1, 1]) == 6)
        #expect(ClusterRearrangements.factorial(0) == 1)
        #expect(ClusterRearrangements.factorial(6) == 720)
        #expect(ClusterRearrangements.factorial(25) == nil)
    }
}
