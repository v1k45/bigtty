import Foundation

/// Where bigtty keeps its files. A test run gets a throwaway folder and a
/// throwaway web data store: nothing it does may reach the user's files.
enum AppPaths {
    static let isTestRun = ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)

    /// `Application Support/bigtty`.
    static let support: URL = {
        let base = isTestRun
            ? FileManager.default.temporaryDirectory.appendingPathComponent("bigtty-tests-\(UUID().uuidString)", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("bigtty", isDirectory: true)
    }()
}
