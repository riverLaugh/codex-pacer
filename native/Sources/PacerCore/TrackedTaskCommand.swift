import Foundation

/// Opt-in local MCP endpoint. It is deliberately separate from the progress
/// reporter installed on SSH hosts and from the read-only percentage tool.
package enum TrackedTaskCommand {
    static let server = "pacer_tasks"
    static let instructions = "For a local background job, register its status file once. The worker updates the file after the chat ends."
    static let definitions: [[String: Any]] = [
        ["name": "track_task",
         "description": "Register a local worker. Generate a UUID for run_id. Atomically replace the UTF-8 JSON status_file with {run_id,state,succeeded,failed,total}. Counts are nonnegative integers. Use running, completed (all items processed), or failed. Reuse the UUID only for this run.",
         "inputSchema": ["type": "object", "properties": ["run_id": ["type": "string", "format": "uuid"],
            "title": ["type": "string"], "status_file": ["type": "string", "description": "Absolute local .json path"]],
            "required": ["run_id", "title", "status_file"], "additionalProperties": false]],
        ["name": "untrack_task", "description": "Forget a registered run when requested. The worker and its status file are preserved.",
         "inputSchema": ["type": "object", "properties": ["run_id": ["type": "string", "format": "uuid"]],
            "required": ["run_id"], "additionalProperties": false]]
    ]

    static func call(_ params: [String: Any], store: TrackedTaskStore) -> [String: Any] {
        func result(_ text: String, error: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": error]
        }
        guard let args = params["arguments"] as? [String: Any],
              let id = (args["run_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return result("Expected a UUID in run_id.", error: true)
        }
        do {
            switch params["name"] as? String {
            case "track_task":
                guard args.count == 3, let path = args["status_file"] as? String, let title = args["title"] as? String
                else { throw TrackedTaskStore.Failure.arguments }
                let meta = params["_meta"] as? [String: Any]
                let context = meta?["x-codex-turn-metadata"] as? [String: Any]
                let thread = (meta?["threadId"] as? String).flatMap(UUID.init(uuidString:))
                let confirmed = (context?["thread_id"] as? String).flatMap(UUID.init(uuidString:))
                try store.register(id: id, title: title, path: path, threadID: thread == confirmed ? thread : nil)
                return result("Tracking " + id.uuidString.lowercased())
            case "untrack_task" where args.count == 1:
                try store.forget(id: id)
                return result("Removed " + id.uuidString.lowercased())
            default: throw TrackedTaskStore.Failure.arguments
            }
        } catch TrackedTaskStore.Failure.arguments {
            return result("Expected run_id, a short title and an absolute local .json path for track_task, or only run_id for untrack_task.", error: true)
        } catch TrackedTaskStore.Failure.conflict {
            return result("This run ID already belongs to another registration.", error: true)
        } catch { return result("Could not update Pacer's local task registry.", error: true) }
    }

    package static func serveIfRequested(arguments: [String], directory: URL, files: any PlatformFileSystem,
                                         read: () throws -> Data?) -> Bool {
        guard let command = arguments.dropFirst().first,
              ["--tracked-tasks-mcp", "--tracked-tasks-snapshot"].contains(command) else { return false }
        let root: URL
        switch arguments.count {
        case 2: root = directory
        case 4 where arguments[2] == "--store" && (arguments[3] as NSString).isAbsolutePath:
            root = URL(fileURLWithPath: arguments[3], isDirectory: true)
        default: return true
        }
        let store = TrackedTaskStore(directory: root, files: files)
        if command == "--tracked-tasks-snapshot" {
            let rows: [[String: Any]] = store.rows(at: Date()).map { row in
                var fields: [String: Any] = ["id": row.id.uuidString.lowercased(), "hasOrigin": row.threadID != nil,
                    "state": row.reading?.status.state.rawValue ?? "pending", "unavailable": row.unavailable]
                if let status = row.reading?.status {
                    fields["succeeded"] = status.succeeded; fields["failed"] = status.failed; fields["total"] = status.total
                }
                return fields
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
        } else {
            var reporter = TaskProgressReporter(trackedTasks: store)
            do {
                while let bytes = try read(), !bytes.isEmpty {
                    for reply in try reporter.receive(bytes) { try FileHandle.standardOutput.write(contentsOf: reply) }
                }
            } catch { }
        }
        return true
    }
}
