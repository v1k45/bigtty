import Foundation

/// A cell in a pane's whole scrollback: row 0 is the oldest line herdr
/// keeps, columns count cells.
public struct ScrollbackPoint: Sendable, Codable, Equatable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// Past the last cell: a backward search from here finds the newest match.
    public static let end = ScrollbackPoint(row: Int(UInt32.max), col: Int(UInt16.max))
}

/// A match; `end` is the last cell of it (inclusive).
public struct ScrollbackRange: Sendable, Codable, Equatable {
    public var start: ScrollbackPoint
    public var end: ScrollbackPoint

    public init(start: ScrollbackPoint, end: ScrollbackPoint) {
        self.start = start
        self.end = end
    }
}

/// Where a pane's viewport sits in its scrollback.
public struct ScrollInfo: Sendable, Codable, Equatable {
    public var offsetFromBottom: Int
    public var maxOffsetFromBottom: Int
    public var viewportRows: Int

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }

    public init(offsetFromBottom: Int, maxOffsetFromBottom: Int, viewportRows: Int) {
        self.offsetFromBottom = offsetFromBottom
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.viewportRows = viewportRows
    }

    /// Scrollback plus screen, in rows.
    public var totalRows: Int { maxOffsetFromBottom + viewportRows }
    /// The scrollback row shown on the viewport's first line.
    public var topRow: Int { totalRows - viewportRows - offsetFromBottom }

    /// The viewport line showing scrollback `row`, if it's on screen.
    public func viewportLine(of row: Int) -> Int? {
        let line = row - topRow
        return line >= 0 && line < viewportRows ? line : nil
    }

    /// The offset that shows `row`: nil when it's already on screen,
    /// otherwise one that puts it in the middle.
    public func offset(revealing row: Int) -> Int? {
        guard viewportLine(of: row) == nil else { return nil }
        return min(max(totalRows - row - viewportRows / 2, 0), maxOffsetFromBottom)
    }
}

/// One answer from herdr's scrollback search: up to about a thousand
/// matches around the current one, and where that one falls among all.
public struct ScrollbackMatches: Sendable, Equatable {
    public var matches: [ScrollbackRange]
    public var total: Int
    /// Index into `matches`.
    public var current: Int?
    /// Index among all `total` matches, oldest first.
    public var currentGlobal: Int?

    public init(matches: [ScrollbackRange], total: Int, current: Int?, currentGlobal: Int?) {
        self.matches = matches
        self.total = total
        self.current = current
        self.currentGlobal = currentGlobal
    }

    public var currentMatch: ScrollbackRange? { current.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }

    /// Where to search from to land on the current match again (herdr skips
    /// a match that starts at the cursor itself).
    public static func cursor(before point: ScrollbackPoint) -> ScrollbackPoint {
        if point.col > 0 { return ScrollbackPoint(row: point.row, col: point.col - 1) }
        if point.row > 0 { return ScrollbackPoint(row: point.row - 1, col: Int(UInt16.max)) }
        return point
    }
}

extension ScrollbackMatches: Decodable {
    enum CodingKeys: String, CodingKey {
        case matches, total, current
        case currentGlobal = "current_global"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matches = try c.decode([ScrollbackRange].self, forKey: .matches)
        total = try c.decode(Int.self, forKey: .total)
        current = try c.decodeIfPresent(Int.self, forKey: .current)
        currentGlobal = try c.decodeIfPresent(Int.self, forKey: .currentGlobal)
    }
}

extension HerdrClient {
    /// The pane's content revision, which a scrollback search must name.
    /// (A copy-mode motion is the one call that reports it.)
    public func contentRevision(paneID: String) async throws -> Int {
        let result = try await call("pane.copy_motion", [
            "pane_id": .string(paneID), "cursor": ["row": 0, "col": 0], "motion": "line_end",
        ])
        guard let revision = result["content_revision"]?.intValue else {
            throw HerdrError.decode("pane.copy_motion: missing content_revision")
        }
        return revision
    }

    /// Searches the pane's whole scrollback (case-sensitive, literal) from
    /// `cursor`; the match found there becomes current. Wraps at either end.
    public func searchScrollback(paneID: String, query: String, from cursor: ScrollbackPoint, backward: Bool) async throws -> ScrollbackMatches {
        // The revision guards against the content moving between calls;
        // a fresh one each time, retried once if output lands in between.
        for attempt in 0..<2 {
            let revision = try await contentRevision(paneID: paneID)
            do {
                let result = try await call("pane.copy_search", [
                    "pane_id": .string(paneID), "query": .string(query),
                    "direction": backward ? "backward" : "forward",
                    "cursor": ["row": .number(Double(cursor.row)), "col": .number(Double(cursor.col))],
                    "content_revision": .number(Double(revision)),
                ])
                return try result.decode(ScrollbackMatches.self)
            } catch let HerdrError.server(code, _) where code == "stale_content" && attempt == 0 {
                continue
            }
        }
        throw HerdrError.server(code: "stale_content", message: "pane content changed")
    }

    public func scrollInfo(paneID: String) async throws -> ScrollInfo? {
        let result = try await call("pane.get", ["pane_id": .string(paneID)])
        return try result["pane"]?["scroll"].map { try $0.decode(ScrollInfo.self) }
    }

    /// Scrolls the pane's viewport (0 is the bottom) for every client.
    @discardableResult
    public func scroll(paneID: String, offsetFromBottom: Int) async throws -> ScrollInfo? {
        let result = try await call("pane.scroll", ["pane_id": .string(paneID), "offset_from_bottom": .number(Double(offsetFromBottom))])
        return try result["pane"]?["scroll"].map { try $0.decode(ScrollInfo.self) }
    }
}
