/**
 * HotwordsView
 *
 * Edit the user's custom hotwords for ASR hint injection.
 * Features: inline quick-add, import/export CSV.
 * Follows xisper-swiftui-complete.pen design: toolbar, info banner, card sections.
 *
 * All mutations are remote-first: API call → success → update local cache.
 */

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Document

private struct HotwordsExportDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    var content: String
    init(content: String) { self.content = content }
    init(configuration: ReadConfiguration) throws { content = "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

// MARK: - Hotword Tag View

private struct HotwordTagView: View {
    let text: String
    let isDeleting: Bool
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignSpacing.xxxs) {
            Text(text)
                .font(.system(size: DesignFont.sm, weight: .medium))
                .foregroundStyle(Color.neutral12)
                .lineLimit(1)

            if isDeleting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.neutral8)
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, DesignSpacing.xxs)
        .padding(.vertical, DesignSpacing.xxxs)
        .background(Color.neutral3)
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .strokeBorder(Color.neutral7.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
        )
        .frame(height: 28)
        .opacity(isDeleting ? 0.5 : 1)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? 0, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let position = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], height: CGFloat) {
        let width = proposal.width ?? 0
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            sizes.append(size)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (positions, sizes, currentY + lineHeight)
    }
}

struct HotwordsView: View {

    private var store: HotwordsStore { .shared }
    @State private var newText = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showExport = false
    @State private var showImport = false
    @State private var exportDoc = HotwordsExportDoc(content: "")
    @State private var isImporting = false
    @State private var isAdding = false
    @State private var isClearing = false
    @State private var showClearConfirm = false
    @State private var deletingIds: Set<String> = []
    @FocusState private var isInputFocused: Bool
    @State private var isInputHovering = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: NSLocalizedString("Custom Hotwords", comment: ""), badge: "\(store.hotwords.count)")
            Divider()
            ScrollView {
                VStack(spacing: DesignSpacing.xs) {
                    // Quick Add — pen: card with shadow, input + add btn + more menu
                    quickAddSection
                    // Tags section — pen: card with shadow
                    tagsSection
                }
                .padding(DesignSpacing.xs)
            }
            .background(Color.neutral1)
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
            }

            // Status messages
            statusMessages
        }
        .frame(minWidth: 360, minHeight: 300)
        .fileExporter(
            isPresented: $showExport,
            document: exportDoc,
            contentTypes: [.plainText],
            defaultFilename: "hotwords_\(exportFilenameDate).csv"
        ) { result in
            if case .success = result { showSuccess(NSLocalizedString("Exported successfully", comment: "")) }
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.plainText, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .task {
            await store.fetch()
        }
        .alert(NSLocalizedString("Clear All Hotwords?", comment: ""), isPresented: $showClearConfirm) {
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("Clear All", comment: ""), role: .destructive) { clearAllHotwords() }
        } message: {
            Text(String(format: NSLocalizedString("This will delete all %lld hotwords. This action cannot be undone.", comment: ""), store.hotwords.count))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
            HStack(spacing: DesignSpacing.xxxs) {
                TextField(NSLocalizedString("e.g., Kubernetes, PostgreSQL...", comment: ""), text: $newText)
                    .textFieldStyle(.plain)
                    .font(.system(size: DesignFont.sm))
                    .padding(.horizontal, DesignSpacing.xxs)
                    .frame(height: 40)
                    .background(Color.neutral3)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.md)
                            .strokeBorder(borderColor, lineWidth: borderWidth)
                    )
                    .shadow(color: isInputFocused ? Color.primary8.opacity(0.12) : Color.clear, radius: 4, x: 0, y: 0)
                    .focused($isInputFocused)
                    .onHover { isInputHovering = $0 }
                    .onSubmit { addHotword() }
                    .animation(.fast, value: isInputFocused)
                    .animation(.fast, value: isInputHovering)
                    .onTapGesture {} // Enable click-outside to dismiss focus
                    .disabled(isAdding)

                Button { addHotword() } label: {
                    HStack(spacing: DesignSpacing.xxxs) {
                        if isAdding {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 14))
                        }
                        Text(NSLocalizedString("Add", comment: ""))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 80, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.md)
                        .fill(Color.primary8)
                )
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)

                Menu {
                    Button {
                        guard !isImporting else { return }
                        showImport = true
                    } label: {
                        Label(NSLocalizedString("Import", comment: ""), systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)

                    Button {
                        exportHotwords()
                    } label: {
                        Label(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.hotwords.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(NSLocalizedString("Clear All", comment: ""), systemImage: "trash")
                    }
                    .disabled(store.hotwords.isEmpty || isClearing)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.neutral12)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.md)
                                .fill(Color.neutral3)
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(NSLocalizedString("Press Enter to add, or paste multiple words separated by commas", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(Color.neutral7)
        }
        .padding(DesignSpacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(Color.neutral2)
                .shadow(color: Color.neutral9.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
            HStack {
                Text(NSLocalizedString("Your Hotwords", comment: ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.neutral12)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if store.hotwords.isEmpty && !store.isLoading {
                VStack(spacing: DesignSpacing.xxxs) {
                    Image(systemName: "text.word.spacing")
                        .font(.system(size: 48))
                        .foregroundStyle(.quaternary)
                    Text(NSLocalizedString("No hotwords yet", comment: ""))
                        .font(.system(size: DesignFont.base, weight: .medium))
                        .foregroundStyle(Color.neutral12)
                    Text(NSLocalizedString("Add domain-specific words to improve recognition accuracy", comment: ""))
                        .font(.system(size: DesignFont.sm))
                        .foregroundStyle(Color.neutral8)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSpacing.md)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.hotwords, id: \.id) { item in
                        HotwordTagView(
                            text: item.text,
                            isDeleting: deletingIds.contains(item.id),
                            onDelete: { deleteHotword(id: item.id) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DesignSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(Color.neutral2)
                .shadow(color: Color.neutral9.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let err = errorMessage ?? store.error {
            HStack {
                Text(err)
                    .font(.system(size: DesignFont.sm))
                    .foregroundStyle(Color.danger10)
                Spacer()
            }
            .padding(.horizontal, DesignSpacing.xs)
            .padding(.vertical, DesignSpacing.xxxs)
            .background(Color.danger2)
        }

        if let msg = successMessage {
            HStack {
                Text(msg)
                    .font(.system(size: DesignFont.sm))
                    .foregroundStyle(Color.success10)
                Spacer()
            }
            .padding(.horizontal, DesignSpacing.xs)
            .padding(.vertical, DesignSpacing.xxxs)
            .background(Color.success2)
        }
    }

    // MARK: - Helpers

    private var exportFilenameDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var borderColor: Color {
        if isInputFocused {
            return Color.primary8
        } else if isInputHovering {
            return Color.neutral7
        } else {
            return Color.neutral5.opacity(0.5)
        }
    }

    private var borderWidth: CGFloat {
        isInputFocused ? 2 : 1
    }

    // MARK: - Actions

    private func deleteHotword(id: String) {
        deletingIds.insert(id)
        Task {
            await store.delete(id: id)
            deletingIds.remove(id)
        }
    }

    private func handleImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard !isImporting else {
            CrashLogger.log("HotwordsView", "handleImport skipped (already importing)")
            return
        }
        isImporting = true

        CrashLogger.log("HotwordsView", "handleImport start url=\(url.lastPathComponent)")
        _ = url.startAccessingSecurityScopedResource()

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            url.stopAccessingSecurityScopedResource()
            CrashLogger.log("HotwordsView", "handleImport failed to read file")
            errorMessage = NSLocalizedString("Failed to read file", comment: "")
            isImporting = false
            return
        }
        url.stopAccessingSecurityScopedResource()

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            errorMessage = NSLocalizedString("Invalid CSV file", comment: "")
            isImporting = false
            return
        }

        // Parse CSV: extract first column from each line
        var texts: [String] = []
        for line in lines {
            let parsed = parseFirstColumn(from: line)
            if !parsed.isEmpty { texts.append(parsed) }
        }

        Task {
            let r = await store.importFromTexts(texts)
            CrashLogger.log("HotwordsView", "handleImport done added=\(r.added) skipped=\(r.skipped) failed=\(r.failed)")
            errorMessage = nil
            if r.added > 0 {
                if r.skipped > 0 {
                    showSuccess(String(format: NSLocalizedString("Imported %d hotwords, skipped %d duplicates", comment: ""), r.added, r.skipped))
                } else {
                    showSuccess(String(format: NSLocalizedString("Imported %d hotwords", comment: ""), r.added))
                }
            } else if r.skipped > 0 {
                showSuccess(String(format: NSLocalizedString("All hotwords already exist, skipped %d", comment: ""), r.skipped))
            }
            if r.failed > 0 {
                errorMessage = r.errorMessage ?? String(format: NSLocalizedString("Failed to import %d hotwords", comment: ""), r.failed)
            }
            isImporting = false
        }
    }

    /// Parse first column from CSV line (handles quoted values).
    private func parseFirstColumn(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("\"") {
            var result = ""
            var i = trimmed.index(after: trimmed.startIndex)
            while i < trimmed.endIndex {
                if trimmed[i] == "\"" {
                    let next = trimmed.index(after: i)
                    if next < trimmed.endIndex, trimmed[next] == "\"" {
                        result += "\""
                        i = next
                    } else {
                        break
                    }
                } else {
                    result.append(trimmed[i])
                }
                i = trimmed.index(after: i)
            }
            return result
        }
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return HotwordItem.normalise(trimmed)
    }

    private func showSuccess(_ msg: String) {
        successMessage = msg
        errorMessage = nil
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { successMessage = nil }
        }
    }

    private func addHotword() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        let words = text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        isAdding = true
        Task {
            var addedCount = 0
            var failedCount = 0

            for word in words {
                let result = await store.add(text: word)
                switch result {
                case .ok:              addedCount += 1
                case .tooLong:         errorMessage = String(format: NSLocalizedString("'%@' too long (max %d characters)", comment: ""), word, HotwordItem.maxCharacters); failedCount += 1
                case .duplicate:       failedCount += 1
                case .networkError(let msg): errorMessage = msg; failedCount += 1
                case .empty:           failedCount += 1
                }
            }

            if addedCount > 0 {
                newText = ""
                showSuccess(String(format: NSLocalizedString("Added %d hotword(s)", comment: ""), addedCount))
            }

            if addedCount == 0 && failedCount > 0 {
                if errorMessage == nil { errorMessage = NSLocalizedString("All words already exist or invalid", comment: "") }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run { errorMessage = nil }
                }
            }

            isAdding = false
        }
    }

    private func exportHotwords() {
        Task {
            let texts = await store.exportTexts()
            let csv = texts.joined(separator: "\n")
            exportDoc = HotwordsExportDoc(content: csv)
            showExport = true
        }
    }

    private func clearAllHotwords() {
        isClearing = true
        Task {
            let result = await store.deleteAll()
            if result.success {
                showSuccess(String(format: NSLocalizedString("Cleared %d hotwords", comment: ""), result.deleted))
            } else {
                errorMessage = result.errorMessage ?? NSLocalizedString("Failed to clear hotwords", comment: "")
            }
            isClearing = false
        }
    }
}
