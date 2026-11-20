import Foundation

package protocol TrackedTaskFiles: PlatformFileSystem {
    /// Atomically install a staged file without replacing an existing registration.
    func publishNew(_ staged: URL, at destination: URL) -> Bool
}

/// A worker owns the status file. The MCP server owns the registration and
/// the desktop reader checkpoints validated counts so a disappearing file or
/// a restarted app does not erase the last observation.
package struct TrackedTaskStore: Sendable {
    package let directory: URL
    package let files: any TrackedTaskFiles
    package init(directory: URL, files: any TrackedTaskFiles) {
        self.directory = directory
        self.files = files
    }

    static let byteLimit = 16 * 1024

    private struct Registration: Codable {
        let generation: UUID
        let title: String
        let path: String
        let threadID: UUID?
        let created: Date
    }
    enum State: String, Codable, Sendable { case running, completed, failed }
    struct Status: Codable, Equatable, Sendable {
        let run_id: UUID
        let state: State
        let succeeded: Int
        let failed: Int
        let total: Int
        func valid(for id: UUID) -> Bool {
            run_id == id && (0...Int(Int32.max)).contains(total) &&
                (0...total).contains(succeeded) && (0...(total - succeeded)).contains(failed) &&
                (state != .completed || succeeded + failed == total)
        }
    }
    struct Reading: Codable, Equatable, Sendable {
        let generation: UUID
        let status: Status
        let updated: Date
    }
    package struct Row: Equatable, Identifiable, Sendable {
        package let id: UUID
        let generation: UUID
        package let title: String
        package let threadID: UUID?
        let reading: Reading?
        let created: Date
        let unavailable: Bool

        package var canClear: Bool {
            reading?.status.state == .completed || reading?.status.state == .failed
        }

        package func detail(at now: Date) -> String {
            guard let reading else { return L10n.text("tracked.pending") }
            let s = reading.status
            var parts = [L10n.text("tracked." + s.state.rawValue),
                         "\(s.succeeded + s.failed)/\(s.total)", L10n.text("tracked.failures", s.failed)]
            if s.state == .running {
                if unavailable { parts.append(L10n.text("tracked.unavailable")) }
                let minutes = Int(max(0, now.timeIntervalSince(reading.updated)) / 60)
                if minutes >= 1 { parts.append(L10n.text("tracked.age", min(Int(Int32.max), minutes))) }
            }
            return parts.joined(separator: " · ")
        }
    }

    package struct Presentation: Codable, Equatable, Identifiable, Sendable {
        package let id: UUID
        package let title: String
        package let detail: String
        package let threadID: UUID?
        package init(_ row: Row, hideProjects: Bool, at now: Date) {
            id = row.id
            title = hideProjects ? L10n.text("activity.hidden_local_name") : row.title
            detail = row.detail(at: now)
            threadID = row.threadID
        }
    }

    static func validPath(_ path: String) -> Bool {
        guard path.utf8.count <= 4096, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.lowercased().hasSuffix(".json") else { return false }
        guard (path as NSString).isAbsolutePath, !path.hasPrefix("//"), !path.hasPrefix("\\\\") else { return false }
        return path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/][^:]*$"#, options: .regularExpression) != nil
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let meta = files.metadata(url), meta.isRegularFile, meta.size <= UInt64(Self.byteLimit),
              let data = try? files.read(url, offset: 0, maximumBytes: Self.byteLimit + 1),
              data.count <= Self.byteLimit else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Publish a complete, immutable registration. A competing registration
    /// with the same UUID can never replace the file chosen by its owner.
    func register(id: UUID, title: String, path: String, threadID: UUID?) throws {
        guard Self.validPath(path), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.arguments }
        let record = Registration(generation: UUID(), title: title, path: path, threadID: threadID, created: Date())
        let destination = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        guard files.replace(temporary, with: try JSONEncoder().encode(record)) else { throw Failure.storage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !files.publishNew(temporary, at: destination) {
            guard let previous = read(Registration.self, from: destination) else { throw Failure.storage }
            guard previous.path == path && previous.title == title else { throw Failure.conflict }
        }
    }

    /// A user-selected link belongs only to this generation of an unlinked run.
    package func link(_ row: Row, to thread: UUID) throws {
        let entry = directory.appendingPathComponent(row.id.uuidString.lowercased() + ".json")
        guard let record = read(Registration.self, from: entry),
              record.generation == row.generation, record.threadID == nil else { throw Failure.conflict }
        let destination = directory.appendingPathComponent(record.generation.uuidString + ".thread")
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        guard files.replace(temporary, with: try JSONEncoder().encode(thread)) else { throw Failure.storage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard files.publishNew(temporary, at: destination) || read(UUID.self, from: destination) == thread else {
            throw Failure.conflict
        }
        guard read(Registration.self, from: entry)?.generation == record.generation else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.conflict
        }
    }

    package func clearFinished(_ row: Row) throws {
        guard row.canClear else { throw Failure.conflict }
        try forget(id: row.id, generation: row.generation)
    }

    func forget(id: UUID, generation: UUID? = nil) throws {
        let entry = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        guard files.metadata(entry) != nil else { return }
        guard let record = read(Registration.self, from: entry) else { throw Failure.storage }
        if let generation, generation != record.generation { throw Failure.conflict }
        do { try FileManager.default.removeItem(at: entry) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        let cache = directory.appendingPathComponent(record.generation.uuidString + ".last")
        let thread = directory.appendingPathComponent(record.generation.uuidString + ".thread")
        try? FileManager.default.removeItem(at: thread)
        if files.metadata(cache) != nil { try? FileManager.default.removeItem(at: cache) }
    }

    enum Failure: Error { case arguments, storage, conflict }

    package func rows(at now: Date) -> [Row] {
        guard let entries = try? files.entries(in: directory) else { return [] }
        return entries.compactMap { entry -> Row? in
            guard entry.pathExtension == "json", let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                  let record = read(Registration.self, from: entry), Self.validPath(record.path) else { return nil }
            let cache = directory.appendingPathComponent(record.generation.uuidString + ".last")
            let saved = read(Reading.self, from: cache)
            var reading = saved.flatMap { $0.generation == record.generation && $0.status.valid(for: id) ? $0 : nil }
            var unavailable = false
            // Terminal observations are sticky, even if the worker reuses the path.
            if reading == nil || reading?.status.state == .running {
                let source = URL(fileURLWithPath: record.path)
                if let meta = files.metadata(source), meta.isRegularFile,
                   let status = read(Status.self, from: source), status.valid(for: id),
                   files.metadata(source) == meta {
                    let next = Reading(generation: record.generation, status: status, updated: meta.modified)
                    if reading != next, let data = try? JSONEncoder().encode(next) { _ = files.replace(cache, with: data) }
                    reading = next
                } else { unavailable = true }
            }
            let thread = record.threadID ?? read(UUID.self, from: directory.appendingPathComponent(record.generation.uuidString + ".thread"))
            return Row(id: id, generation: record.generation, title: record.title, threadID: thread, reading: reading,
                       created: record.created, unavailable: unavailable)
        }.sorted { lhs, rhs in
            let active = lhs.reading?.status.state ?? .running
            let other = rhs.reading?.status.state ?? .running
            if (active == .running) != (other == .running) { return active == .running }
            if lhs.created != rhs.created { return lhs.created > rhs.created }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
