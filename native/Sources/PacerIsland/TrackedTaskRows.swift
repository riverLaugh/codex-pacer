import SwiftUI
import PacerCore

struct TrackedTaskRows: View {
    @ObservedObject var model: IslandModel
    @State private var sessions: [Session] = []
    @State private var selecting: UUID?

    private struct Session: Identifiable {
        let id: UUID
        let title: String?
    }

    var body: some View {
        ForEach(model.trackedRows) { row in
            let item = TrackedTaskStore.Presentation(row, hideProjects: model.hideProjects, at: model.now)
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(verbatim: item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let thread = item.threadID, let url = URL(string: "codex://threads/" + thread.uuidString.lowercased()) {
                        Link(destination: url) {
                            Label(sessionName(thread), systemImage: "arrow.up.forward").lineLimit(1)
                        }.help(L10n.text("tracked.open"))
                    } else {
                        Button(L10n.text("tracked.link")) { selecting = row.id }
                            .popover(isPresented: Binding(get: { selecting == row.id },
                                set: { if !$0 { selecting = nil } })) {
                                sessionPicker(for: row)
                            }
                    }
                }
                Spacer(minLength: 4)
                if row.canClear {
                    Button(L10n.text("tracked.clear")) { model.updateTrackedTask(row) }
                        .help(L10n.text("tracked.clear_help"))
                }
            }
            .buttonStyle(.link).font(.system(size: 11))
            .padding(.vertical, 4)
        }
        .task(id: model.home) { await loadSessions() }
    }

    private func sessionName(_ id: UUID) -> String {
        if !model.hideProjects {
            let live = model.activities.first { $0.provider == .codex && $0.sourceHostID == nil &&
                $0.threadID?.lowercased() == id.uuidString.lowercased() }
            if let title = live?.title ?? sessions.first(where: { $0.id == id })?.title, !title.isEmpty {
                return title
            }
        }
        return L10n.text("tracked.session_id", String(id.uuidString.lowercased().suffix(8)))
    }

    private func sessionPicker(for row: TrackedTaskStore.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("tracked.link")).font(.headline)
            if sessions.isEmpty {
                Text(L10n.text("tracked.no_sessions")).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sessions) { session in
                            Button {
                                selecting = nil
                                model.updateTrackedTask(row, linkTo: session.id)
                            } label: {
                                Text(verbatim: sessionName(session.id)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 230)
            }
        }
        .padding(12).frame(width: 260)
        .task { await loadSessions() }
    }

    private func loadSessions() async {
        let home = model.home
        let entries = await Task.detached(priority: .utility) { SessionIndex.entries(home: home, limit: 100) }.value
        guard !Task.isCancelled else { return }
        var seen = Set<UUID>()
        sessions = entries.compactMap { entry in
            guard let id = entry.threadID, seen.insert(id).inserted else { return nil }
            return Session(id: id, title: entry.title)
        }
    }
}
