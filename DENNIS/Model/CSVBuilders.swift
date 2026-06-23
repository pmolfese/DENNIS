//
//  CSVBuilders.swift
//  DENNIS
//
//  Builds CSV tables from a completed dual PCA for export to statistical
//  software: factor scores (subjects × factor·condition), temporal loadings
//  (time × temporal factor), and spatial loadings (channel × combined factor).
//

import Foundation

@MainActor
enum CSVBuilders {

    /// One row per subject; one column per combined factor × condition. When
    /// `microvolts` is true, standardized scores are multiplied by the factor's
    /// reconstructed amplitude (var_sd-scaled temporal × spatial loading, reduced
    /// by the chosen measure) — the EP Toolkit microvolt conversion.
    static func factorScores(_ bundle: AnalysisStore.DualBundle,
                             microvolts: Bool,
                             measure: AnalysisStore.MicrovoltMeasure,
                             windowStartMS: Double,
                             windowEndMS: Double,
                             label: (String) -> String) -> String {
        let r = bundle.result
        let nCells = bundle.conditionNames.count
        let nSubjects = bundle.subjectNames.count

        var headers = ["Subject"]
        var specs: [(t: Int, s: Int, c: Int)] = []
        for factor in r.factors {
            for (ci, cond) in bundle.conditionNames.enumerated() {
                headers.append("\(label(factor.name)) \(cond)")
                specs.append((factor.firstIndex, factor.secondIndex, ci))
            }
        }

        var lines = [headers.map(escape).joined(separator: ",")]
        for j in 0..<nSubjects {
            var row = [escape(bundle.subjectNames[j])]
            for spec in specs {
                guard r.second.indices.contains(spec.t) else { row.append(""); continue }
                let step = r.second[spec.t]
                let amp = microvolts
                    ? factorAmplitude(r, t: spec.t, s: spec.s, measure: measure,
                                      windowStartMS: windowStartMS, windowEndMS: windowEndMS)
                    : 1.0
                let idx = spec.c + j * nCells
                let value = (idx < step.scores.rows && spec.s < step.scores.cols)
                    ? step.scores[idx, spec.s] * amp : Double.nan
                row.append(format(value))
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// One row per time point; one column per temporal factor loading.
    static func temporalLoadings(_ bundle: AnalysisStore.DualBundle,
                                 label: (String) -> String) -> String {
        let first = bundle.result.first
        let prefix = bundle.result.firstMode.factorPrefix
        let nTimes = first.pattern.rows
        let times = bundle.result.firstTimesMS

        var headers = ["Time_ms"]
        for t in 0..<first.nFactors { headers.append(label("\(prefix)\(t + 1)")) }

        var lines = [headers.map(escape).joined(separator: ",")]
        for i in 0..<nTimes {
            let time = i < times.count ? times[i] : Double(i)
            var row = [format(time)]
            for t in 0..<first.nFactors { row.append(format(first.pattern[i, t])) }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// One row per channel; one column per combined factor's spatial loading.
    static func spatialLoadings(_ bundle: AnalysisStore.DualBundle,
                                label: (String) -> String) -> String {
        let r = bundle.result
        var headers = ["Channel"]
        for factor in r.factors { headers.append(label(factor.name)) }

        var lines = [headers.map(escape).joined(separator: ",")]
        for ch in 0..<bundle.nChannels {
            var row = ["\(ch + 1)"]
            for factor in r.factors {
                guard r.second.indices.contains(factor.firstIndex) else { row.append(""); continue }
                let pattern = r.second[factor.firstIndex].pattern
                let value = (ch < pattern.rows && factor.secondIndex < pattern.cols)
                    ? pattern[ch, factor.secondIndex] : Double.nan
                row.append(format(value))
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Exact reconstructed amplitude (µV) of a combined factor: the var_sd-scaled
    /// temporal loading reduced by `measure`, times the var_sd-scaled spatial
    /// loading at its peak channel. Mirrors EP Toolkit's microvolt conversion
    /// (`diag(varSD)·FacPat` then a peak/mean measure).
    static func factorAmplitude(_ r: TwoStepPCAResult, t: Int, s: Int,
                                measure: AnalysisStore.MicrovoltMeasure,
                                windowStartMS: Double, windowEndMS: Double) -> Double {
        // Temporal µV loading = var_sd · pattern for temporal factor t.
        let tPattern = r.first.pattern.column(t)
        let tSD = r.first.variableSD
        let tLoad = (0..<tPattern.count).map { i in
            tPattern[i] * (i < tSD.count ? tSD[i] : 1)
        }
        let amplitudeT: Double
        switch measure {
        case .peak:
            amplitudeT = signedPeak(tLoad)
        case .meanWindow:
            let times = r.firstTimesMS
            let lo = min(windowStartMS, windowEndMS), hi = max(windowStartMS, windowEndMS)
            let inWindow = (0..<tLoad.count).filter { i in
                let ms = i < times.count ? times[i] : Double(i)
                return ms >= lo && ms <= hi
            }
            let used = inWindow.isEmpty ? Array(0..<tLoad.count) : inWindow
            amplitudeT = used.reduce(0.0) { $0 + tLoad[$1] } / Double(used.count)
        }

        // Spatial µV loading = var_sd · pattern for spatial factor s; peak channel.
        guard r.second.indices.contains(t) else { return amplitudeT }
        let sPattern = r.second[t].pattern.column(s)
        let sSD = r.second[t].variableSD
        let sLoad = (0..<sPattern.count).map { i in
            sPattern[i] * (i < sSD.count ? sSD[i] : 1)
        }
        return amplitudeT * signedPeak(sLoad)
    }

    /// The value with the largest magnitude (sign preserved).
    private static func signedPeak(_ v: [Double]) -> Double {
        v.max(by: { abs($0) < abs($1) }) ?? 0
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6g", value) : ""
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
