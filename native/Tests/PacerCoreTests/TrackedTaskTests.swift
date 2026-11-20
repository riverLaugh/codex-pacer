import Foundation
import XCTest
@testable import PacerCore
#if os(Windows)
import PacerEngineSupport
#else
import PacerMacSupport
#endif

final class TrackedTaskTests: XCTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent("worker.json") }
    private var store: TrackedTaskStore {
        #if os(Windows)
        let files = WindowsFileSystem()
        #else
        let files = MacFileSystem()
        #endif
        return TrackedTaskStore(directory: root.appendingPathComponent("registry"), files: files)
    }
    private let id = UUID()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ state: String = "running", _ ok: Int = 340, _ failed: Int = 2,
                       _ total: Int = 1000, as run: UUID? = nil) throws {
        try JSONSerialization.data(withJSONObject: ["run_id": (run ?? id).uuidString, "state": state,
            "succeeded": ok, "failed": failed, "total": total]).write(to: file, options: .atomic)
    }
    private func register(_ run: UUID? = nil) throws {
        try store.register(id: run ?? id, title: "PDF batch", path: file.path, threadID: nil)
    }
    func testIndependentRunsAndIdempotentRegistration() throws {
        try register(); try register(); try register(UUID())
        XCTAssertEqual(store.rows(at: Date()).count, 2)
        XCTAssertThrowsError(try store.register(id: id, title: "PDF batch",
            path: root.appendingPathComponent("other.json").path, threadID: nil))
    }
    func testFreshReaderKeepsLastGoodReadingUntilWorkerExplicitlyEnds() throws {
        try register()
        XCTAssertNil(store.rows(at: Date()).first?.reading)
        try write()
        XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.succeeded, 340)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try XCTUnwrap(store.rows(at: Date()).first).unavailable)
        for invalid in ["{", "[]", String(repeating: "x", count: 17000)] {
            try Data(invalid.utf8).write(to: file, options: .atomic)
            XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.failed, 2)
        }
        try write("completed", 1, 0, 1, as: UUID())
        XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.succeeded, 340)
        try write("completed", 1, 1, 1)
        XCTAssertTrue(try XCTUnwrap(store.rows(at: Date()).first).unavailable)
        try write("running", 998, 2)
        XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.state, .running)
        try write("completed", 998, 2)
        XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.state, .completed)
        try write()
        XCTAssertEqual(store.rows(at: Date()).first?.reading?.status.succeeded, 998)
    }
    func testOriginAndHiddenTitleAreIndependentOfSessionLifetime() throws {
        let thread = UUID()
        try store.register(id: id, title: "PDF batch", path: file.path, threadID: thread)
        let row = try XCTUnwrap(store.rows(at: Date()).first)
        let normal = TrackedTaskStore.Presentation(row, hideProjects: false, at: Date())
        let hidden = TrackedTaskStore.Presentation(row, hideProjects: true, at: Date())
        XCTAssertEqual(normal.title, "PDF batch")
        XCTAssertNotEqual(hidden.title, normal.title)
        XCTAssertEqual(hidden.threadID, thread)
    }

    func testManuallyLinkThenClearOneFinishedRun() throws {
        let other = UUID(), thread = UUID()
        try register(); try register(other)
        func row() throws -> TrackedTaskStore.Row {
            try XCTUnwrap(store.rows(at: Date()).first { $0.id == id })
        }
        XCTAssertFalse(try row().canClear)
        try store.link(try row(), to: thread)
        XCTAssertEqual(try row().threadID, thread)
        try write()
        XCTAssertThrowsError(try store.clearFinished(try row()))
        for ending in ["completed", "failed"] {
            try write(ending, 1, 0, 1)
            XCTAssertTrue(try row().canClear)
            try store.clearFinished(try row())
            XCTAssertEqual(store.rows(at: Date()).map(\.id), [other])
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            if ending == "completed" {
                try register()
                XCTAssertNil(try row().threadID)
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("registry").path)
            .contains { $0.hasSuffix(".thread") })
    }

    func testTrustedOriginAndNewRegistrationAreProtectedFromStaleActions() throws {
        try register()
        let old = try XCTUnwrap(store.rows(at: Date()).first)
        try store.forget(id: id)
        let thread = UUID()
        try store.register(id: id, title: "Next run", path: file.path, threadID: thread)
        XCTAssertThrowsError(try store.link(old, to: UUID()))
        let fresh = try XCTUnwrap(store.rows(at: Date()).first)
        XCTAssertThrowsError(try store.link(fresh, to: UUID()))
        XCTAssertEqual(store.rows(at: Date()).first?.threadID, thread)
    }

    func testTerminalOutcomesAndUntrackPreserveWorkerFile() throws {
        for (state, ok, failed, total) in [("completed", 0, 0, 0), ("completed", 1, 0, 1), ("failed", 1, 2, 10)] {
            let run = UUID()
            try register(run); try write(state, ok, failed, total, as: run)
            let row = try XCTUnwrap(store.rows(at: Date()).first)
            XCTAssertEqual(row.reading?.status.state.rawValue, state)
            XCTAssertEqual(row.reading?.status.failed, failed)
            try store.forget(id: run); try store.forget(id: run)
            XCTAssertTrue(store.rows(at: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }
}

