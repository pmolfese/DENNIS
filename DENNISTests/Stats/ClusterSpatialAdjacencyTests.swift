//
//  ClusterSpatialAdjacencyTests.swift
//  DENNISTests
//

import Testing
@testable import DENNIS

struct ClusterSpatialAdjacencyTests {
    private let layout = SensorLayout(
        name: "Irregular line",
        positions: [
            SensorPosition(channelIndex: 0, x: 0.0, y: 0),
            SensorPosition(channelIndex: 1, x: 0.1, y: 0),
            SensorPosition(channelIndex: 2, x: 0.2, y: 0),
            SensorPosition(channelIndex: 3, x: 0.4, y: 0),
        ]
    )

    @Test func medianNearestNeighborDistanceUsesTheMontageScale() throws {
        let spacing = try #require(ClusterSpatialAdjacency.medianNearestNeighborDistance(
            channelIndices: [0, 1, 2, 3],
            layout: layout
        ))
        // Nearest distances are .1, .1, .1 and .2. The even-sample median is
        // the mean of the middle pair, both .1.
        #expect(abs(spacing - 0.1) < 1e-12)
    }

    @Test func twoLocatedSensorsStillDefineARadiusScale() throws {
        let layout = SensorLayout(
            name: "Pair",
            positions: [
                SensorPosition(channelIndex: 0, x: -0.2, y: 0),
                SensorPosition(channelIndex: 1, x: 0.2, y: 0),
            ]
        )
        let spacing = try #require(ClusterSpatialAdjacency.medianNearestNeighborDistance(
            channelIndices: [0, 1],
            layout: layout
        ))
        #expect(abs(spacing - 0.4) < 1e-12)
    }

    @Test func increasingMontageRelativeRadiiProducesNestedGraphs() throws {
        let spacing = try #require(ClusterSpatialAdjacency.medianNearestNeighborDistance(
            channelIndices: [0, 1, 2, 3],
            layout: layout
        ))
        let radii = [1.25, 1.7, 2.1].map { $0 * spacing }
        let graphs = radii.map { radius in
            ClusterSpatialAdjacency.build(
                channelIndices: [0, 1, 2, 3],
                layout: layout,
                configuration: .init(method: .distance, distance: radius)
            )
        }

        for index in 1..<graphs.count {
            for channel in graphs[index].indices {
                #expect(Set(graphs[index - 1][channel]).isSubset(of: Set(graphs[index][channel])))
            }
        }
        let narrow = ClusterSpatialAdjacency.summarize(graphs[0])
        let broad = ClusterSpatialAdjacency.summarize(graphs[2])
        #expect(narrow.isolatedChannelCount == 1)
        #expect(broad.isolatedChannelCount == 0)
        #expect(broad.meanNeighborCount > narrow.meanNeighborCount)
    }
}
