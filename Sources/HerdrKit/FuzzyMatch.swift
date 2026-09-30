import Foundation

/// fzf-style fuzzy matching for the jump palette: the query's letters in
/// order, scored so that what a person means ranks first. A prefix beats a
/// word start beats a run of consecutive letters beats scattered ones;
/// gaps cost. Case-insensitive, on UTF-16 units, O(query × candidate).
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        public let score: Int
        /// Matched positions in the candidate, as UTF-16 offsets.
        public let positions: [Int]
    }

    static let base = 16
    static let gap = 10
    static let consecutive = 10

    /// Scores `candidate` against a query; nil when the letters aren't all
    /// there in order. An empty query matches everything with score 0.
    public static func match(_ query: String, in candidate: String) -> Result? {
        let q = Array(query.lowercased().utf16)
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        let original = Array(candidate.utf16)
        let c = Array(candidate.lowercased().utf16)
        // Lowercasing can change the length for rare characters; positions
        // would drift, so fall back to plain containment.
        guard c.count == original.count else {
            return candidate.lowercased().contains(query.lowercased()) ? Result(score: 1, positions: []) : nil
        }
        let n = q.count, m = c.count
        guard m >= n else { return nil }

        // Quick reject: every query unit must appear in order.
        var probe = 0
        for unit in c where probe < n && unit == q[probe] { probe += 1 }
        guard probe == n else { return nil }

        let none = Int.min / 4
        var previous = [Int](repeating: none, count: m)
        var from = [[Int32]](repeating: [Int32](repeating: -1, count: m), count: n)
        for i in 0..<n {
            var current = [Int](repeating: none, count: m)
            // Best score of the previous row at some k < j - 1 (a gap).
            var gapBest = none
            var gapAt = -1
            for j in 0..<m {
                if i > 0, j >= 2, previous[j - 2] > gapBest {
                    gapBest = previous[j - 2]
                    gapAt = j - 2
                }
                guard c[j] == q[i] else { continue }
                let bonus = boundaryBonus(original, j)
                if i == 0 {
                    // Earlier starts rank higher; the very first letter most.
                    current[j] = base + bonus + (j == 0 ? 12 : 0) - min(j, 12)
                    continue
                }
                var score = none
                if j >= 1, previous[j - 1] > none {
                    score = previous[j - 1] + base + bonus + consecutive
                    from[i][j] = Int32(j - 1)
                }
                if gapAt >= 0, gapBest - gap + base + bonus > score {
                    score = gapBest - gap + base + bonus
                    from[i][j] = Int32(gapAt)
                }
                current[j] = score
            }
            previous = current
        }
        var end = -1
        for j in 0..<m where previous[j] > none && (end < 0 || previous[j] > previous[end]) { end = j }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: n)
        var j = end
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            if i > 0 { j = Int(from[i][j]) }
        }
        // Shorter candidates win ties: "api" over "api-server-staging".
        var result = Result(score: previous[end] - min(m / 10, 6), positions: positions)
        // The query as one piece ("coupon" in "Checkout coupon field")
        // beats letters picked from different words.
        if let run = contiguous(q, in: c, original: original), run.score >= result.score - 12 {
            result = Result(score: max(run.score, result.score) + 1, positions: run.positions)
        }
        return result
    }

    /// The best exact occurrence of the query, scored like a run.
    private static func contiguous(_ q: [UInt16], in c: [UInt16], original: [UInt16]) -> Result? {
        let n = q.count, m = c.count
        guard m >= n else { return nil }
        var best: Result?
        var start = 0
        while start + n <= m {
            if c[start] == q[0], Array(c[start..<(start + n)]) == q {
                var score = base + boundaryBonus(original, start) + (start == 0 ? 12 : 0) - min(start, 12)
                for j in (start + 1)..<(start + n) { score += base + boundaryBonus(original, j) + consecutive }
                score -= min(m / 10, 6)
                if best == nil || score > best!.score { best = Result(score: score, positions: Array(start..<(start + n))) }
            }
            start += 1
        }
        return best
    }

    /// Every word of the query (split on spaces) must match; scores add up.
    public static func matchWords(_ query: String, in candidate: String) -> Result? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count > 1 else { return match(query.trimmingCharacters(in: .whitespaces), in: candidate) }
        var total = 0
        var positions = Set<Int>()
        for word in words {
            guard let result = match(word, in: candidate) else { return nil }
            total += result.score
            positions.formUnion(result.positions)
        }
        return Result(score: total, positions: positions.sorted())
    }

    /// Starts of words score more: the start, after a separator, or a
    /// lower-to-upper case change (camelCase).
    private static func boundaryBonus(_ s: [UInt16], _ j: Int) -> Int {
        guard j > 0 else { return 10 }
        let previous = s[j - 1], current = s[j]
        if separators.contains(previous) { return 9 }
        let lower = previous >= 97 && previous <= 122
        let upper = current >= 65 && current <= 90
        return lower && upper ? 7 : 0
    }

    private static let separators: Set<UInt16> = Set(" -_/.:@|\\(),[]#".utf16)
}
