import Foundation
import Testing
@testable import Wink

@Suite("StoragePaths directory contract")
struct StoragePathsTests {

    @Test
    func appSupportDirectoryReturnsNilWhenDirectoryCreationFails() {
        // A valid-looking URL to a directory that does not exist bypasses the
        // callers' nil fallbacks (e.g. UsageTracker's :memory: database) and
        // fails later at first write/open instead (Issue #267).
        let url = StoragePaths.appSupportDirectory(fileManager: CreateFailingFileManager())
        #expect(url == nil)
    }

    @Test
    func appSupportDirectoryReturnsExistingDirectoryWithoutCreating() {
        let fileManager = ExistingDirectoryFileManager()
        let url = StoragePaths.appSupportDirectory(fileManager: fileManager)
        #expect(url?.lastPathComponent == StoragePaths.appDirectoryName)
        #expect(fileManager.createDirectoryCallCount == 0)
    }

    @Test
    func appSupportDirectoryReturnsNilWhenNoApplicationSupportExists() {
        let url = StoragePaths.appSupportDirectory(fileManager: NoSearchPathFileManager())
        #expect(url == nil)
    }

    @Test
    func liveAppSupportDirectoryIsUsable() throws {
        let url = try #require(StoragePaths.appSupportDirectory())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class CreateFailingFileManager: FileManager, @unchecked Sendable {
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [URL(fileURLWithPath: "/nonexistent-root/Application Support")]
    }

    override func fileExists(atPath path: String) -> Bool {
        false
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class ExistingDirectoryFileManager: FileManager, @unchecked Sendable {
    private(set) var createDirectoryCallCount = 0

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [URL(fileURLWithPath: "/tmp/storage-paths-tests/Application Support")]
    }

    override func fileExists(atPath path: String) -> Bool {
        true
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createDirectoryCallCount += 1
    }
}

private final class NoSearchPathFileManager: FileManager, @unchecked Sendable {
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        []
    }
}
