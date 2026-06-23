//
//  LevelInference.swift
//  DENNIS
//
//  "Fill by example" for between-subject factor levels: given a few file names
//  the user has already labelled (e.g. `6mo_4001m_6x25.ref` → "m"), learn a rule
//  that extracts the same code from the file name, then apply it to the rest.
//
//  The rule space is intentionally small and explainable: pick a token (file
//  names split on non-alphanumerics), counted from the start or the end, and a
//  part of that token (whole / first char / last char). We accept the first rule
//  that reproduces every labelled example, and only auto-fill a file when the
//  extracted code matches one of the values the user actually typed — so files
//  with no matching code are left blank rather than filled with noise.
//

import Foundation

enum LevelInference {
    private enum TokenPart: CaseIterable { case last, first, whole }

    private struct Rule {
        let tokenIndex: Int
        let fromEnd: Bool
        let part: TokenPart
    }

    /// Split a file-name base into alphanumeric tokens, e.g.
    /// "6mo_4001m_6x25.ref" → ["6mo", "4001m", "6x25", "ref"].
    private static func tokenize(_ name: String) -> [String] {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func apply(_ rule: Rule, to name: String) -> String? {
        let tokens = tokenize(name)
        guard !tokens.isEmpty else { return nil }
        let index = rule.fromEnd ? tokens.count - 1 - rule.tokenIndex : rule.tokenIndex
        guard tokens.indices.contains(index) else { return nil }
        let token = tokens[index]
        switch rule.part {
        case .whole: return token
        case .first: return token.first.map(String.init)
        case .last: return token.last.map(String.init)
        }
    }

    /// Learn a rule from labelled examples and return inferred values for the
    /// blanks. `labelled` is (fileNameBase, typedValue); `blanks` are file-name
    /// bases needing a value. Returns fileNameBase → inferred value.
    static func fill(labelled: [(name: String, value: String)],
                     blanks: [String]) -> [String: String] {
        let examples = labelled.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard examples.count >= 2 else { return [:] }

        let knownValues = Set(examples.map { $0.value.lowercased() })
        // Canonical casing: first typed spelling for each lowercased value.
        var canonical: [String: String] = [:]
        for example in examples where canonical[example.value.lowercased()] == nil {
            canonical[example.value.lowercased()] = example.value
        }

        let maxTokens = examples.map { tokenize($0.name).count }.max() ?? 0
        guard maxTokens > 0 else { return [:] }

        for fromEnd in [true, false] {
            for part in TokenPart.allCases {
                for tokenIndex in 0..<maxTokens {
                    let rule = Rule(tokenIndex: tokenIndex, fromEnd: fromEnd, part: part)
                    let consistent = examples.allSatisfy { example in
                        apply(rule, to: example.name)?.lowercased() == example.value.lowercased()
                    }
                    if consistent {
                        return applyRule(rule, blanks: blanks, knownValues: knownValues, canonical: canonical)
                    }
                }
            }
        }
        return [:]
    }

    private static func applyRule(_ rule: Rule,
                                  blanks: [String],
                                  knownValues: Set<String>,
                                  canonical: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for name in blanks {
            guard let extracted = apply(rule, to: name)?.lowercased(),
                  knownValues.contains(extracted) else { continue }
            result[name] = canonical[extracted] ?? extracted
        }
        return result
    }
}
