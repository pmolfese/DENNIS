//
//  DENNISTests.swift
//  DENNISTests
//
//  Created by Molfese, Peter  [E] on 6/23/26.
//

import Testing
import Foundation
@testable import DENNIS

struct ImportInferenceTests {

    /// Build a temp folder tree of empty `.mff` packages and return the root.
    private func makeTree(_ relativePackagePaths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DENNISTest-\(UUID().uuidString)", isDirectory: true)
        for path in relativePackagePaths {
            let pkg = root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        }
        return root
    }

    @Test func expandsFolderToMFFPackagesWithoutDescending() throws {
        let root = try makeTree([
            "6mo/Monozygotic/a.mff",
            "6mo/Dizygotic/b.mff",
            "12mo/Monozygotic/c.mff",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let packages = StudyImporter.expandToMFFPackages([root])
        #expect(packages.count == 3)
        #expect(packages.allSatisfy { $0.pathExtension == "mff" })
    }

    @Test func infersTwoFactorsFromTwinsLayout() throws {
        let root = try makeTree([
            "6mo/Monozygotic/a.mff",
            "6mo/Dizygotic/b.mff",
            "12mo/Monozygotic/c.mff",
            "18mo/Dizygotic/d.mff",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let packages = StudyImporter.expandToMFFPackages([root])
        let (factorCount, levels) = StudyImporter.inferLevels(for: packages)

        #expect(factorCount == 2)   // Age × TwinType
        let a = packages.first { $0.lastPathComponent == "a.mff" }!
        #expect(levels[a] == ["6mo", "Monozygotic"])
        let d = packages.first { $0.lastPathComponent == "d.mff" }!
        #expect(levels[d] == ["18mo", "Dizygotic"])
    }

    @Test func flatFolderFallsBackToSingleFactor() throws {
        let root = try makeTree(["a.mff", "b.mff"])
        defer { try? FileManager.default.removeItem(at: root) }

        let packages = StudyImporter.expandToMFFPackages([root])
        let (factorCount, levels) = StudyImporter.inferLevels(for: packages)

        #expect(factorCount == 1)
        // Both share the same parent folder name → one group.
        #expect(Set(levels.values.map { $0.first ?? "" }).count == 1)
    }

    @Test func infersSexCodeFromFileNames() {
        let labelled = [
            (name: "6mo_4001m_6x25.ref", value: "m"),
            (name: "12mo_5901f_6x25.ref", value: "f"),
        ]
        let blanks = [
            "18mo_6002m_6x25.ref",   // → m
            "6mo_7003f_6x25.ref",    // → f
            "9mo_5902_6x25.ref",     // no code → stays blank
        ]
        let filled = LevelInference.fill(labelled: labelled, blanks: blanks)
        #expect(filled["18mo_6002m_6x25.ref"] == "m")
        #expect(filled["6mo_7003f_6x25.ref"] == "f")
        #expect(filled["9mo_5902_6x25.ref"] == nil)
    }

    @Test func grandAverageMeansAcrossSubjects() {
        let url = URL(fileURLWithPath: "/tmp/x.mff")
        func makeDataset(_ value: Float) -> Dataset {
            let condition = Condition(name: "A",
                                      samples: [[value, value], [value, value]],
                                      sampleCount: 2,
                                      baselineSamples: 1)
            return Dataset(name: "s", sourceURL: url, conditions: [condition],
                           samplingRate: 250, channelCount: 2, loadState: .loaded)
        }
        let datasets = [makeDataset(2), makeDataset(4)]
        let ga = GrandAverage.compute(datasets: datasets, condition: "A")
        #expect(ga?.contributing == 2)
        #expect(ga?.samples.first?.first == 3)       // mean of 2 and 4
        #expect(ga?.centroid.first == 3)
        #expect(ga?.baselineSamples == 1)
    }

    @Test func groupTreeNestsByFactorOrder() {
        let study = Study(factors: [DesignFactor(name: "Age"), DesignFactor(name: "TwinType")])
        let url = URL(fileURLWithPath: "/tmp/x.mff")
        study.add(Dataset(name: "a", sourceURL: url, levels: ["6mo", "MZ"]))
        study.add(Dataset(name: "b", sourceURL: url, levels: ["6mo", "DZ"]))
        study.add(Dataset(name: "c", sourceURL: url, levels: ["12mo", "MZ"]))

        let tree = study.groupTree()
        #expect(tree.count == 2)                    // 6mo, 12mo
        let sixMo = tree.first { $0.level == "6mo" }!
        #expect(sixMo.children.count == 2)          // MZ, DZ
        #expect(sixMo.children.allSatisfy { $0.datasets.count == 1 })
    }
}
