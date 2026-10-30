@testable import bigtty
import Foundation
import Testing

/// Tests build real panes and write real files, which must all land in a
/// temporary folder, never in the user's Library.
@MainActor @Suite struct TestIsolationTests {
    let temporary = FileManager.default.temporaryDirectory.path

    @Test func everyFileGoesToATemporaryFolder() {
        #expect(AppPaths.isTestRun)
        for folder in [AppPaths.support, BrowserPageState.folder, WebExtensions.folder] {
            #expect(folder.path.hasPrefix(temporary), "\(folder.path)")
        }
    }

    @Test func webDataStaysInMemory() {
        #expect(!BrowserPage.sharedDataStore.isPersistent)
    }
}
