//
//  FIFAveragedLoader.swift
//  DENNIS
//
//  Reads MNE / Neuromag evoked FIF files (`*-ave.fif`) into the same model as
//  an averaged MFF.  DENNIS analyses condition averages, so raw and epoched
//  FIF containers are intentionally rejected instead of being misrepresented
//  as one-subject averages.
//

import Compression
import Foundation

enum FIFAveragedLoaderError: LocalizedError {
    case notAveraged
    case truncated
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notAveraged:
            return "DENNIS imports averaged (evoked, *-ave.fif) FIF files. Raw and epoched FIF files must be averaged by condition first."
        case .truncated:
            return "The FIF file is truncated."
        case .malformed(let detail):
            return "This FIF file could not be read: \(detail)"
        }
    }
}

nonisolated final class FIFAveragedLoader {
    func inspectConditions(at url: URL) throws -> [String] {
        try withScopedAccess(to: url) { try read(url: url, includeSamples: false).names }
    }

    func load(at url: URL) throws -> AveragedMFF {
        try withScopedAccess(to: url) { try read(url: url, includeSamples: true).recording! }
    }

    private func withScopedAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func read(url: URL, includeSamples: Bool) throws -> (names: [String], recording: AveragedMFF?) {
        let data = url.pathExtension.lowercased() == "gz"
            ? try FIFGzipDecoder.read(url)
            : try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = try FIFTagReader(data: data)
        let info = try measurementInfo(reader)
        let blocks = reader.blocks(kind: FIF.evokedBlock)
        guard !blocks.isEmpty else { throw FIFAveragedLoaderError.notAveraged }

        var conditions: [AveragedMFF.ConditionData] = []
        for block in blocks {
            guard let epoch = block.first(where: { $0.kind == FIF.epochData }) else { continue }
            let (channels, samples, values) = try epoch.matrix()
            guard channels == info.channels.count else {
                throw FIFAveragedLoaderError.malformed("an evoked matrix has \(channels) channels but the file describes \(info.channels.count)")
            }
            let name = block.first(where: { $0.kind == FIF.comment })?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let conditionName = (name?.isEmpty == false) ? name! : "condition \(conditions.count + 1)"
            guard includeSamples else {
                conditions.append(.init(name: conditionName, samples: [], sampleCount: samples, baselineSamples: 0))
                continue
            }
            var data = [[Float]](repeating: [], count: channels)
            for channel in 0..<channels {
                // Evoked FIF values use `cal` (not `range × cal`), matching MNE.
                data[channel] = (0..<samples).map { Float(values[channel * samples + $0] * info.channels[channel].calibration) }
            }
            let first = block.first(where: { $0.kind == FIF.firstSample })?.intValue ?? 0
            let firstTime = block.first(where: { $0.kind == FIF.firstTime })?.doubleValue
            let onset = firstTime.map { Int((-$0 * info.samplingRate).rounded()) }
                ?? max(-first, 0)
            conditions.append(.init(name: conditionName, samples: data, sampleCount: samples,
                                    baselineSamples: min(max(onset, 0), samples)))
        }
        guard !conditions.isEmpty else { throw FIFAveragedLoaderError.notAveraged }
        let names = conditions.map(\.name)
        guard includeSamples else { return (names, nil) }
        return (names, AveragedMFF(sourceURL: url,
                                   subjectName: url.deletingPathExtension().lastPathComponent,
                                   samplingRate: info.samplingRate,
                                   channelCount: info.channels.count,
                                   sensorLayout: layout(channels: info.channels),
                                   conditions: conditions))
    }

    private func measurementInfo(_ reader: FIFTagReader) throws -> FIFMeasurementInfo {
        guard let block = reader.blocks(kind: FIF.measInfoBlock).first,
              let rate = block.first(where: { $0.kind == FIF.sfreq })?.doubleValue,
              rate > 0 else { throw FIFAveragedLoaderError.malformed("missing measurement information") }
        let channels = try block.filter { $0.kind == FIF.chInfo }.map(FIFChannelInfo.init)
        guard !channels.isEmpty else { throw FIFAveragedLoaderError.malformed("missing channel information") }
        return .init(samplingRate: rate, channels: channels)
    }

    private func layout(channels: [FIFChannelInfo]) -> SensorLayout? {
        let positioned = channels.enumerated().compactMap { index, channel -> (Int, Double, Double)? in
            guard channel.kind == FIF.eeg, let point = channel.position else { return nil }
            return (index, point.0, point.1)
        }
        guard positioned.count >= 3 else { return nil }
        let centerX = positioned.map(\.1).reduce(0, +) / Double(positioned.count)
        let centerY = positioned.map(\.2).reduce(0, +) / Double(positioned.count)
        let radius = positioned.map { hypot($0.1 - centerX, $0.2 - centerY) }.max() ?? 0
        guard radius > 0 else { return nil }
        return SensorLayout(name: "FIF electrode locations", positions: positioned.map {
            SensorPosition(channelIndex: $0.0, x: ($0.1 - centerX) / radius, y: ($0.2 - centerY) / radius)
        })
    }
}

private nonisolated enum FIF {
    static let fileID: Int32 = 100
    static let blockStart: Int32 = 104
    static let blockEnd: Int32 = 105
    static let comment: Int32 = 206
    static let firstSample: Int32 = 208
    static let firstTime: Int32 = 229
    static let sfreq: Int32 = 201
    static let chInfo: Int32 = 203
    static let epochData: Int32 = 302
    static let measInfoBlock: Int32 = 101
    static let evokedBlock: Int32 = 104
    static let typeFloat: Int32 = 4
    static let typeDouble: Int32 = 5
    static let matrixFlag: Int32 = 0x40000000
    static let eeg: Int32 = 2
}

private nonisolated struct FIFMeasurementInfo { let samplingRate: Double; let channels: [FIFChannelInfo] }

private nonisolated struct FIFChannelInfo {
    let kind: Int32
    let calibration: Double
    let position: (Double, Double, Double)?

    init(_ tag: FIFTag) throws {
        guard tag.data.count >= 96 else { throw FIFAveragedLoaderError.truncated }
        kind = tag.int32(at: 8)
        calibration = Double(tag.float32(at: 16))
        let x = Double(tag.float32(at: 24)), y = Double(tag.float32(at: 28)), z = Double(tag.float32(at: 32))
        position = (x.isFinite && y.isFinite && z.isFinite && hypot(x, y) > 1e-9) ? (x, y, z) : nil
    }
}

private nonisolated struct FIFTag {
    let kind: Int32; let type: Int32; let data: Data
    var baseType: Int32 { type & ~FIF.matrixFlag }
    var intValue: Int { Int(int32(at: 0)) }
    var doubleValue: Double? {
        switch baseType { case FIF.typeFloat: return Double(float32(at: 0)); case FIF.typeDouble: return float64(at: 0); default: return nil }
    }
    var stringValue: String { String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
    func int32(at offset: Int) -> Int32 { Int32(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })) }
    func float32(at offset: Int) -> Float { Float(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })) }
    func float64(at offset: Int) -> Double { Double(bitPattern: UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })) }
    func matrix() throws -> (Int, Int, [Double]) {
        guard (type & FIF.matrixFlag) != 0, data.count >= 12 else { throw FIFAveragedLoaderError.malformed("epoch data is not a matrix") }
        let ndim = Int(int32(at: data.count - 4))
        guard ndim == 2 else { throw FIFAveragedLoaderError.malformed("evoked data is not two-dimensional") }
        let columns = Int(int32(at: data.count - 12)), rows = Int(int32(at: data.count - 8))
        guard rows > 0, columns > 0 else { throw FIFAveragedLoaderError.malformed("invalid evoked matrix dimensions") }
        let count = rows * columns, width = baseType == FIF.typeDouble ? 8 : 4
        guard data.count >= count * width + 12 else { throw FIFAveragedLoaderError.truncated }
        switch baseType {
        case FIF.typeFloat: return (rows, columns, (0..<count).map { Double(float32(at: $0 * 4)) })
        case FIF.typeDouble: return (rows, columns, (0..<count).map { float64(at: $0 * 8) })
        default: throw FIFAveragedLoaderError.malformed("unsupported evoked sample type \(baseType)")
        }
    }
}

private nonisolated struct FIFTagReader {
    let tags: [FIFTag]
    init(data: Data) throws {
        var tags: [FIFTag] = [], offset = 0, first = true
        while offset + 16 <= data.count {
            func value(_ relative: Int) -> Int32 { Int32(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + relative, as: UInt32.self) })) }
            let kind = value(0), type = value(4), size = Int(value(8)), next = Int(value(12))
            guard !first || kind == FIF.fileID else { throw FIFAveragedLoaderError.malformed("not a FIF file") }
            first = false
            guard size >= 0, offset + 16 + size <= data.count else { throw FIFAveragedLoaderError.truncated }
            tags.append(FIFTag(kind: kind, type: type, data: data[(offset + 16)..<(offset + 16 + size)]))
            if next == -1 { break }; offset = next > 0 ? next : offset + 16 + size
        }
        guard !tags.isEmpty else { throw FIFAveragedLoaderError.malformed("not a FIF file") }; self.tags = tags
    }
    func blocks(kind: Int32) -> [[FIFTag]] {
        var output: [[FIFTag]] = [], current: [FIFTag]?, depth = 0
        for tag in tags {
            if current == nil { if tag.kind == FIF.blockStart && tag.intValue == kind { current = []; depth = 1 }; continue }
            if tag.kind == FIF.blockStart { depth += 1 }
            if tag.kind == FIF.blockEnd { depth -= 1; if depth == 0 { output.append(current!); current = nil; continue } }
            current!.append(tag)
        }
        return output
    }
}

/// Gzip is a small wrapper around raw DEFLATE. `InputFilter` handles the
/// payload; this consumes the variable-length wrapper header first.
private nonisolated enum FIFGzipDecoder {
    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        do {
            try consumeHeader(from: handle)
            let filter = try InputFilter<Data>(.decompress, using: .zlib, bufferCapacity: 1_048_576) { count in
                let data = try handle.read(upToCount: count) ?? Data()
                return data.isEmpty ? nil : data
            }
            var output = Data()
            while let chunk = try filter.readData(ofLength: 1_048_576), !chunk.isEmpty { output.append(chunk) }
            guard !output.isEmpty else { throw FIFAveragedLoaderError.truncated }
            return output
        } catch let error as FIFAveragedLoaderError {
            throw error
        } catch {
            throw FIFAveragedLoaderError.malformed("invalid gzip stream (\(error.localizedDescription))")
        }
    }

    private static func consumeHeader(from handle: FileHandle) throws {
        guard let header = try handle.read(upToCount: 10), header.count == 10 else { throw FIFAveragedLoaderError.truncated }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8, bytes[3] & 0xe0 == 0 else {
            throw FIFAveragedLoaderError.malformed("invalid gzip header")
        }
        func byte() throws -> UInt8 {
            guard let data = try handle.read(upToCount: 1), let value = data.first else { throw FIFAveragedLoaderError.truncated }
            return value
        }
        let flags = bytes[3]
        if flags & 0x04 != 0 { let length = Int(UInt16(try byte()) | UInt16(try byte()) << 8); for _ in 0..<length { _ = try byte() } }
        if flags & 0x08 != 0 { while try byte() != 0 {} }
        if flags & 0x10 != 0 { while try byte() != 0 {} }
        if flags & 0x02 != 0 { _ = try byte(); _ = try byte() }
    }
}
