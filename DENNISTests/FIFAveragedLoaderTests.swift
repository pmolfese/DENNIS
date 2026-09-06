import Foundation
import Testing
@testable import DENNIS

@Suite("Averaged FIF import")
struct FIFAveragedLoaderTests {
    @Test("loads evoked conditions and applies channel calibration")
    func loadsEvokedFIF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dennis-test-\(UUID().uuidString).fif")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeFixture().write(to: url)

        let loader = FIFAveragedLoader()
        #expect(try loader.inspectConditions(at: url) == ["faces"])
        let result = try loader.load(at: url)
        #expect(result.samplingRate == 250)
        #expect(result.channelCount == 2)
        #expect(result.conditions[0].sampleCount == 3)
        #expect(result.conditions[0].baselineSamples == 1)
        #expect(result.conditions[0].samples[0] == [2, 4, 6])
        #expect(result.conditions[0].samples[1] == [8, 10, 12])
    }

    @Test("loads a gzip-compressed evoked FIF")
    func loadsCompressedEvokedFIF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dennis-test-\(UUID().uuidString).fif.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try gzip(makeFixture()).write(to: url)
        let result = try FIFAveragedLoader().load(at: url)
        #expect(result.conditions.map(\.name) == ["faces"])
        #expect(result.conditions[0].samples[1] == [8, 10, 12])
    }

    private func makeFixture() -> Data {
        var data = Data()
        func int32(_ value: Int32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        func float(_ value: Float) -> Data { var value = value.bitPattern.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        func tag(_ kind: Int32, _ type: Int32, _ payload: Data, next: Int32 = 0) {
            data.append(int32(kind)); data.append(int32(type)); data.append(int32(Int32(payload.count))); data.append(int32(next)); data.append(payload)
        }
        func block(_ kind: Int32, begin: Bool) { tag(begin ? 104 : 105, 3, int32(kind)) }
        func channel(calibration: Float, x: Float, y: Float) -> Data {
            var payload = Data(repeating: 0, count: 96)
            func put(_ offset: Int, _ value: Data) { payload.replaceSubrange(offset..<(offset + value.count), with: value) }
            put(8, int32(2)); put(16, float(calibration)); put(24, float(x)); put(28, float(y)); return payload
        }

        tag(100, 31, Data(repeating: 0, count: 20))
        block(100, begin: true); block(101, begin: true)
        tag(201, 4, float(250)); tag(203, 30, channel(calibration: 2, x: -1, y: 0)); tag(203, 30, channel(calibration: 2, x: 1, y: 0))
        block(101, begin: false); block(100, begin: false)
        block(104, begin: true); tag(206, 10, Data("faces".utf8)); tag(208, 3, int32(-1))
        var matrix = [Float(1), 2, 3, 4, 5, 6].reduce(into: Data()) { $0.append(float($1)) }
        matrix.append(int32(3)); matrix.append(int32(2)); matrix.append(int32(2))
        tag(302, 0x40000004, matrix); block(104, begin: false)
        tag(110, 0, Data(), next: -1)
        return data
    }

    private func gzip(_ input: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03])
        var offset = 0
        repeat {
            let length = min(65_535, input.count - offset)
            output.append(offset + length == input.count ? 1 : 0)
            var count = UInt16(length).littleEndian, inverse = (~UInt16(length)).littleEndian
            withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
            withUnsafeBytes(of: &inverse) { output.append(contentsOf: $0) }
            output.append(input.subdata(in: offset..<(offset + length)))
            offset += length
        } while offset < input.count
        var checksum = crc32(input).littleEndian, size = UInt32(input.count).littleEndian
        withUnsafeBytes(of: &checksum) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }
}
