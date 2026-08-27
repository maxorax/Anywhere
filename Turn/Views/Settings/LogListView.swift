//
//  LogListView.swift
//  Turn
//
//  Created by NodePassProject on 3/30/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct LogListView: View {
    @Environment(LogsModel.self) private var logsModel
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive

    /// Captured once so the exported file keeps a stable name while the share
    /// sheet is open, instead of churning on every redraw.
    @State private var sessionDate = Date()

    var body: some View {
        content
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    selectButton
                }
                if editMode == .inactive {
                    ToolbarItem(placement: .topBarTrailing) {
                        exportButton
                    }
                }
            }
            .task(id: editMode) {
                guard editMode == .inactive else { return }
                selection.removeAll()
                while !Task.isCancelled {
                    await logsModel.poll()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onDisappear { logsModel.clear() }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var selectButton: some View {
        if editMode == .active {
            Button(selection.isEmpty ? "Cancel" : "Copy (\(selection.count))") {
                if selection.isEmpty {
                    editMode = .inactive
                } else {
                    copySelected()
                    selection.removeAll()
                    editMode = .inactive
                }
            }
        } else {
            Button("Select") {
                editMode = .active
            }
            .disabled(logsModel.logs.isEmpty)
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        ShareLink(
            item: exportDocument,
            preview: SharePreview(exportDocument.fileName)
        ) {
            Label("Export Logs", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .disabled(logsModel.logs.isEmpty)
    }

    private var exportDocument: LogArchiveDocument {
        LogArchiveDocument(
            text: LogArchive.export(logsModel.logs, at: sessionDate),
            fileName: LogArchive.fileName(at: sessionDate)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if logsModel.logs.isEmpty {
            ContentUnavailableView("No Recent Logs", systemImage: "checkmark.circle")
        } else {
            List(logsModel.logs.reversed(), selection: $selection) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.level.iconName)
                        .foregroundStyle(entry.level.color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.message)
                            .font(.system(size: 10).monospaced())
                            .lineLimit(3)
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = entry.formatted
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .animation(.default, value: logsModel.logs)
        }
    }

    private func copySelected() {
        let text = logsModel.logs
            .filter { selection.contains($0.id) }
            .map(\.formatted)
            .joined(separator: "\n")
        UIPasteboard.general.string = text
    }
}

/// Wraps the exported text so `ShareLink` hands it over as a file rather than
/// as a wall of pasted text.
private struct LogArchiveDocument: Transferable {
    let text: String
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { document in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.fileName)
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.fileName }
    }
}

extension LogsModel.LogEntry {
    var formatted: String {
        let time = timestamp.formatted(.dateTime.hour().minute().second())
        return "\(time) [\(level.token)] \(message)"
    }
}

extension LogsModel.LogLevel {
    var iconName: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
