import SwiftUI
import PacerCore

struct TrackedTaskRows: View {
    let rows: [TrackedTaskStore.Presentation]
    var body: some View {
        ForEach(rows) { item in
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(verbatim: item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let thread = item.threadID, let url = URL(string: "codex://threads/" + thread.uuidString.lowercased()) {
                    Link(destination: url) { Image(systemName: "arrow.up.forward") }
                        .accessibilityLabel(L10n.text("tracked.open"))
                }
            }
            .padding(.vertical, 4)
        }
    }
}
