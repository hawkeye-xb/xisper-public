/**
 * HistoryView
 *
 * Transcription history with date grouping ("Today", "Yesterday", date headers).
 * Follows xisper-swiftui-complete.pen design: toolbar, search, card layout.
 */

import SwiftData
import SwiftUI

struct HistoryView: View {

    @Environment(\.modelContext) private var context
    @Query(
        filter: nil,
        sort: [SortDescriptor(\TranscribeRecord.createdAt, order: .reverse)],
        animation: .default
    )
    private var recentRecords: [TranscribeRecord]

    @State private var detailRecord: TranscribeRecord?
    @State private var searchText = ""
    @State private var showToast = false
    @State private var toastMessage = "Copied to clipboard"
    @State private var retranscribingIds: Set<String> = []
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchHovering = false

    // Selection mode
    @State private var isSelectionMode = false
    @State private var selectedIds: Set<String> = []

    private var displayRecords: [TranscribeRecord] {
        let limited = Array(recentRecords.prefix(500))
        
        // Filter out service errors without audio files (cannot be retranscribed)
        let validRecords = limited.filter { record in
            let isServiceError = record.rawTranscribeContent == RecordingCoordinator.asrServiceErrorMarker
            if isServiceError && record.audioFilePath.isEmpty {
                return false  // Hide unrecoverable errors
            }
            return true
        }
        
        if searchText.isEmpty { return validRecords }
        return validRecords.filter {
            $0.transcribeContent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var grouped: [(key: String, records: [TranscribeRecord])] {
        let cal = Calendar.current
        var dict: [String: [TranscribeRecord]] = [:]
        var order: [String] = []

        for r in displayRecords {
            let label: String
            if cal.isDateInToday(r.createdAt) {
                label = NSLocalizedString("Today", comment: "")
            } else if cal.isDateInYesterday(r.createdAt) {
                label = NSLocalizedString("Yesterday", comment: "")
            } else {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                label = f.string(from: r.createdAt)
            }
            if dict[label] == nil { order.append(label) }
            dict[label, default: []].append(r)
        }

        return order.map { (key: $0, records: dict[$0]!) }
    }

    private var searchBorderColor: Color {
        if isSearchFocused {
            return Color.primary8
        } else if isSearchHovering {
            return Color.neutral7
        } else {
            return Color.neutral5.opacity(0.5)
        }
    }

    private var searchBorderWidth: CGFloat {
        isSearchFocused ? 2 : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: NSLocalizedString("History", comment: ""), badge: "\(recentRecords.count)") {
                HStack(spacing: DesignSpacing.xxs) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(isSearchFocused ? Color.primary8 : Color.neutral7)
                        TextField(NSLocalizedString("Search...", comment: ""), text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($isSearchFocused)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.neutral7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DesignSpacing.xs)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.neutral3)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.sm)
                            .strokeBorder(searchBorderColor, lineWidth: searchBorderWidth)
                    )
                    .shadow(color: isSearchFocused ? Color.primary8.opacity(0.12) : Color.clear, radius: 4, x: 0, y: 0)
                    .onHover { isSearchHovering = $0 }
                    .animation(.fast, value: isSearchFocused)
                    .animation(.fast, value: isSearchHovering)

                    // Select mode toggle
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode { selectedIds.removeAll() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isSelectionMode ? "checklist.checked" : "checklist")
                                .font(.system(size: 14))
                            Text(NSLocalizedString("Select", comment: "Select mode button"))
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(isSelectionMode ? Color.primary8 : Color.neutral8)
                        .padding(.horizontal, DesignSpacing.xxs)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.sm)
                                .fill(isSelectionMode ? Color.primary8.opacity(0.1) : Color.neutral3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignRadius.sm)
                                .strokeBorder(isSelectionMode ? Color.primary8.opacity(0.4) : Color.neutral5.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            if displayRecords.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? NSLocalizedString("No recordings yet", comment: "") : NSLocalizedString("No results", comment: ""),
                    systemImage: searchText.isEmpty ? "waveform.and.mic" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? NSLocalizedString("Your transcription history will appear here.", comment: "") : NSLocalizedString("Try a different search term.", comment: ""))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.neutral1)
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSpacing.xs) {
                        ForEach(grouped, id: \.key) { group in
                            DateGroupView(
                                group: group,
                                retranscribingIds: retranscribingIds,
                                isSelectionMode: isSelectionMode,
                                selectedIds: $selectedIds,
                                onCopy: copyText,
                                onDetail: { record in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        detailRecord = record
                                    }
                                },
                                onDelete: deleteRecord,
                                onRetranscribe: retranscribeRecord
                            )
                        }

                        if recentRecords.count >= 500 {
                            Text(NSLocalizedString("Showing 500 most recent records", comment: ""))
                                .font(.system(size: DesignFont.xs))
                                .foregroundStyle(Color.neutral7)
                                .padding(.vertical, DesignSpacing.xxxs)
                        }
                    }
                    .padding(DesignSpacing.xs)
                }
                .background(Color.neutral1)
                .contentShape(Rectangle())
                .onTapGesture {
                    isSearchFocused = false
                }
            }
        }
        .overlay(alignment: .top) {
            if showToast {
                ToastView(message: toastMessage)
                    .padding(.top, DesignSpacing.xxs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let record = detailRecord {
                RecordDetailSheet(
                    record: record,
                    isRetranscribing: retranscribingIds.contains(record.id),
                    onRetranscribe: { retranscribeRecord(record) },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            detailRecord = nil
                        }
                    },
                    onDelete: {
                        deleteRecord(record)
                        withAnimation(.easeOut(duration: 0.2)) {
                            detailRecord = nil
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelectionMode && !selectedIds.isEmpty {
                SelectionActionBar(
                    selectedCount: selectedIds.count,
                    onMergeAndCopy: mergeAndCopy,
                    onDismiss: exitSelectionMode
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, DesignSpacing.sm)
            }
        }
        .onKeyPress(.escape) {
            if isSelectionMode {
                withAnimation(.easeOut(duration: 0.2)) {
                    exitSelectionMode()
                }
                return .handled
            }
            return .ignored
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedIds.removeAll()
    }

    private func mergeAndCopy() {
        let selected = displayRecords.filter { selectedIds.contains($0.id) }
        let sorted = selected.sorted { $0.createdAt < $1.createdAt }
        let merged = sorted
            .map { $0.transcribeContent }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !merged.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(merged, forType: .string)
        showToastMessage(String(format: NSLocalizedString("Merged %d records and copied", comment: ""), selectedIds.count))

        withAnimation(.easeOut(duration: 0.2)) {
            exitSelectionMode()
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToastMessage(NSLocalizedString("Copied to clipboard", comment: ""))
    }

    private func deleteRecord(_ record: TranscribeRecord) {
        context.delete(record)
        try? context.save()
    }

    private func retranscribeRecord(_ record: TranscribeRecord) {
        guard !retranscribingIds.contains(record.id) else { return }
        retranscribingIds.insert(record.id)

        Task {
            do {
                let result = try await RetranscribeService.retranscribe(record: record)
                showToastMessage(NSLocalizedString("Retranscribed successfully", comment: ""))
                _ = result
            } catch {
                showToastMessage(String(format: NSLocalizedString("Retranscribe failed: %@", comment: ""), error.localizedDescription))
            }
            retranscribingIds.remove(record.id)
        }
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showToast = false
            }
        }
    }
}

// MARK: - Date group

private struct DateGroupView: View {
    let group: (key: String, records: [TranscribeRecord])
    let retranscribingIds: Set<String>
    let isSelectionMode: Bool
    @Binding var selectedIds: Set<String>
    let onCopy: (String) -> Void
    let onDetail: (TranscribeRecord) -> Void
    let onDelete: (TranscribeRecord) -> Void
    let onRetranscribe: (TranscribeRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
            Text(group.key)
                .font(.system(size: 12, weight: DesignFont.weight_semibold))
                .foregroundStyle(Color.neutral12)

            VStack(spacing: DesignSpacing.xxxs) {
                ForEach(group.records) { record in
                    RecordCard(
                        record: record,
                        isRetranscribing: retranscribingIds.contains(record.id),
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedIds.contains(record.id),
                        onToggleSelect: {
                            if selectedIds.contains(record.id) {
                                selectedIds.remove(record.id)
                            } else {
                                selectedIds.insert(record.id)
                            }
                        },
                        onCopy: { onCopy(record.transcribeContent) },
                        onDetail: { onDetail(record) },
                        onDelete: { onDelete(record) },
                        onRetranscribe: { onRetranscribe(record) }
                    )
                }
            }
        }
    }
}

// MARK: - Record card — pen: radius-lg, padding $spacing-sm, gap $spacing-xs, border hover primary

private struct RecordCard: View {
    let record: TranscribeRecord
    let isRetranscribing: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onCopy: () -> Void
    let onDetail: () -> Void
    let onDelete: () -> Void
    let onRetranscribe: () -> Void

    @State private var isHovered = false
    @State private var showDeleteAlert = false
    @State private var justCopied = false

    private var isServiceError: Bool {
        record.rawTranscribeContent == RecordingCoordinator.asrServiceErrorMarker
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: record.createdAt)
    }

    private var durationLabel: String {
        String(format: "%.0fs", record.duration)
    }

    private var rawCharsCount: Int {
        record.rawTranscribeContent?.count ?? record.transcribeContent.count
    }

    private var charsLabel: String {
        String(format: NSLocalizedString("%d chars", comment: ""), rawCharsCount)
    }

    private var modeLabel: String {
        switch record.actionId {
        case "translate": NSLocalizedString("Translate", comment: "Mode label")
        case "ask":       NSLocalizedString("ASK", comment: "Mode label")
        default:          NSLocalizedString("Dictation", comment: "Mode label")
        }
    }

    private var modeColor: Color {
        switch record.actionId {
        case "translate": Color.info8
        case "ask":       Color.warning8
        default:          Color.primary8
        }
    }

    private var cardBorderColor: Color {
        if isSelectionMode && isSelected {
            return Color.primary8
        } else if isServiceError {
            return Color.warning8.opacity(0.3)
        } else if isHovered {
            return Color.primary8
        } else {
            return Color.neutral3
        }
    }

    private var cardFillColor: Color {
        if isServiceError {
            return Color.warning8.opacity(0.05)
        } else if isSelectionMode && isSelected {
            return Color.primary8.opacity(0.05)
        } else if isHovered {
            return Color.neutral3
        } else {
            return Color.neutral2
        }
    }

    var body: some View {
        HStack(spacing: DesignSpacing.xxs) {
            // Checkbox in selection mode
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.primary8 : Color.neutral6)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleSelect() }
            }

            VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                HStack {
                    HStack(spacing: DesignSpacing.xxs) {
                        Text(timeLabel)
                            .font(.system(size: 12, weight: DesignFont.weight_medium, design: .monospaced))
                            .foregroundStyle(Color.neutral7)

                        Text(durationLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.neutral7)

                        if !isServiceError {
                            Text(charsLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.neutral7)
                        }

                        Text(modeLabel)
                            .font(.system(size: 10, weight: DesignFont.weight_semibold))
                            .foregroundStyle(modeColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(modeColor.opacity(0.1))
                            )
                    }

                    Spacer()

                    if !isSelectionMode {
                        HStack(spacing: DesignSpacing.xxxs) {
                            if isServiceError {
                                Button { onRetranscribe() } label: {
                                    if isRetranscribing {
                                        ProgressView()
                                            .controlSize(.mini)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.warning8)
                                            .frame(width: 16, height: 16)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isRetranscribing)
                                .help(NSLocalizedString("Retry transcription", comment: ""))
                            } else {
                                Button { onDetail() } label: {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.neutral8)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                                .opacity(isHovered ? 1 : 0)

                                Button {
                                    onCopy()
                                    justCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { justCopied = false }
                                } label: {
                                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 14))
                                        .foregroundStyle(justCopied ? Color.success8 : Color.neutral8)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                                .opacity(isHovered ? 1 : 0)
                            }

                            if !record.audioFilePath.isEmpty {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: record.audioFilePath)]
                                    )
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.neutral8)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                                .opacity(isHovered ? 1 : 0)
                            }

                            Button { showDeleteAlert = true } label: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.danger8)
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .opacity(isHovered ? 1 : 0)
                        }
                    }
                }

                if isServiceError {
                    HStack(spacing: DesignSpacing.xxxs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warning8)
                        Text(NSLocalizedString("ASR service error — tap retry to re-transcribe", comment: ""))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.warning8)
                    }
                } else {
                    Text(record.transcribeContent.isEmpty ? NSLocalizedString("(No content)", comment: "") : record.transcribeContent)
                        .font(.system(size: 14))
                        .foregroundStyle(record.transcribeContent.isEmpty ? Color.neutral7 : Color.neutral12)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(DesignSpacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .strokeBorder(cardBorderColor, lineWidth: isSelectionMode && isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleSelect()
            } else if !isServiceError {
                onCopy()
                justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { justCopied = false }
            }
        }
        .onHover { isHovered = $0 }
        .animation(.fast, value: isHovered)
        .animation(.fast, value: isSelected)
        .alert(NSLocalizedString("Delete Record", comment: ""), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("Delete", comment: ""), role: .destructive) { onDelete() }
        } message: {
            Text(NSLocalizedString("This record will be permanently deleted.", comment: ""))
        }
    }
}

// MARK: - Detail modal — pen: modal 600×540, radius-xl, shadow; full-area scrim via overlay (not .sheet)

private struct RecordDetailSheet: View {
    let record: TranscribeRecord
    let isRetranscribing: Bool
    let onRetranscribe: () -> Void
    let onDismiss: () -> Void
    let onDelete: () -> Void
    @State private var copiedProcessed = false
    @State private var copiedRaw = false
    @State private var showDeleteAlert = false

    private var isServiceError: Bool {
        record.rawTranscribeContent == RecordingCoordinator.asrServiceErrorMarker
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: record.createdAt)
    }

    private var durationLabel: String {
        let d = record.duration
        return d < 60 ? String(format: "%.1f s", d) : String(format: "%d min %d s", Int(d) / 60, Int(d) % 60)
    }

    private var rawCharsCount: Int {
        record.rawTranscribeContent?.count ?? record.transcribeContent.count
    }

    private var cpmLabel: String {
        guard record.duration > 0 else { return "0" }
        let cpm = (Double(rawCharsCount) / record.duration) * 60
        return String(format: "%.0f", cpm)
    }

    private var modeLabel: String {
        switch record.actionId {
        case "translate": NSLocalizedString("Translate", comment: "Mode label")
        case "ask":       NSLocalizedString("ASK", comment: "Mode label")
        default:          NSLocalizedString("Dictation", comment: "Mode label")
        }
    }

    private var modeColor: Color {
        switch record.actionId {
        case "translate": Color.info8
        case "ask":       Color.warning8
        default:          Color.primary8
        }
    }

    var body: some View {
        ZStack {
            Color.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(dateLabel)
                        .font(.system(size: DesignFont.base, weight: DesignFont.weight_medium))
                        .foregroundStyle(Color.neutral12)
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.neutral8)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DesignSpacing.xs)
                .frame(height: 56)
                .background(Color.neutral2)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        // Metadata cards
                        HStack(spacing: DesignSpacing.xxxs) {
                            MetadataItem(label: NSLocalizedString("Duration", comment: ""), value: durationLabel)
                            MetadataItem(label: NSLocalizedString("Raw Chars", comment: ""), value: "\(rawCharsCount)")
                            MetadataItem(label: NSLocalizedString("Speed", comment: ""), value: "\(cpmLabel) CPM")
                        }

                        // Mode + Audio path
                        VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                            HStack(spacing: DesignSpacing.xxs) {
                                Text(NSLocalizedString("Mode", comment: ""))
                                    .font(.system(size: DesignFont.xs, weight: DesignFont.weight_semibold))
                                    .foregroundStyle(Color.neutral7)
                                    .textCase(.uppercase)

                                Text(modeLabel)
                                    .font(.system(size: 11, weight: DesignFont.weight_semibold))
                                    .foregroundStyle(modeColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(modeColor.opacity(0.1)))
                            }

                            if !record.audioFilePath.isEmpty {
                                HStack(spacing: DesignSpacing.xxxs) {
                                    Text(NSLocalizedString("Audio", comment: ""))
                                        .font(.system(size: DesignFont.xs, weight: DesignFont.weight_semibold))
                                        .foregroundStyle(Color.neutral7)
                                        .textCase(.uppercase)

                                    Text(record.audioFilePath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.neutral9)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting(
                                            [URL(fileURLWithPath: record.audioFilePath)]
                                        )
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.primary8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Divider()

                        // Processed text section
                        VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                            HStack {
                                Text(String(format: NSLocalizedString("Processed (%lld chars)", comment: ""), record.transcribeContent.count))
                                    .font(.system(size: DesignFont.xs, weight: DesignFont.weight_semibold))
                                    .foregroundStyle(Color.neutral8)
                                    .textCase(.uppercase)

                                Spacer()

                                CopyButton(copied: $copiedProcessed) {
                                    copyToClipboard(record.transcribeContent)
                                    copiedProcessed = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedProcessed = false }
                                }
                            }

                            Text(record.transcribeContent.isEmpty ? NSLocalizedString("(No content)", comment: "") : record.transcribeContent)
                                .font(.system(size: DesignFont.sm))
                                .foregroundStyle(record.transcribeContent.isEmpty ? Color.neutral7 : Color.neutral12)
                                .textSelection(.enabled)
                                .padding(DesignSpacing.xxs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignRadius.md)
                                        .fill(Color.neutral2)
                                )
                        }

                        if let raw = record.rawTranscribeContent, !raw.isEmpty {
                            Divider()

                            // Raw ASR section
                            VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
                                HStack {
                                    Text(String(format: NSLocalizedString("Raw ASR (%lld chars)", comment: ""), raw.count))
                                        .font(.system(size: DesignFont.xs, weight: DesignFont.weight_semibold))
                                        .foregroundStyle(Color.neutral8)
                                        .textCase(.uppercase)

                                    Spacer()

                                    CopyButton(copied: $copiedRaw) {
                                        copyToClipboard(raw)
                                        copiedRaw = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedRaw = false }
                                    }
                                }

                                Text(raw)
                                    .font(.system(size: DesignFont.sm))
                                    .foregroundStyle(Color.neutral12)
                                    .textSelection(.enabled)
                                    .padding(DesignSpacing.xxs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignRadius.md)
                                            .fill(Color.neutral2)
                                    )
                            }
                        }
                    }
                    .padding(DesignSpacing.xs)
                }
                .background(Color.neutral1)

                Divider()

                // Bottom actions
                HStack(spacing: DesignSpacing.xxxs) {
                    if isServiceError {
                        Button { onRetranscribe() } label: {
                            HStack(spacing: DesignSpacing.xxxxs) {
                                if isRetranscribing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 13))
                                }
                                Text(isRetranscribing ? NSLocalizedString("Retranscribing...", comment: "") : NSLocalizedString("Retry Transcription", comment: ""))
                                    .font(.system(size: 13, weight: DesignFont.weight_medium))
                            }
                            .foregroundStyle(Color.warning8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSpacing.xxxs)
                            .background(
                                RoundedRectangle(cornerRadius: DesignRadius.sm)
                                    .strokeBorder(Color.warning8.opacity(0.5), lineWidth: 1)
                                    .background(Color.warning8.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetranscribing)
                    }

                    if !record.audioFilePath.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: record.audioFilePath)]
                            )
                        } label: {
                            HStack(spacing: DesignSpacing.xxxxs) {
                                Image(systemName: "folder")
                                    .font(.system(size: 13))
                                Text(NSLocalizedString("Show in Finder", comment: ""))
                                    .font(.system(size: 13, weight: DesignFont.weight_medium))
                            }
                            .foregroundStyle(Color.neutral12)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSpacing.xxxs)
                            .background(
                                RoundedRectangle(cornerRadius: DesignRadius.sm)
                                    .strokeBorder(Color.neutral4, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button { showDeleteAlert = true } label: {
                        HStack(spacing: DesignSpacing.xxxxs) {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                            Text(NSLocalizedString("Delete", comment: ""))
                                .font(.system(size: 13, weight: DesignFont.weight_medium))
                        }
                        .foregroundStyle(Color.danger8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSpacing.xxxs)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.sm)
                                .strokeBorder(Color.danger8.opacity(0.5), lineWidth: 1)
                                .background(Color.danger8.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(DesignSpacing.xs)
                .background(Color.neutral2)
            }
            .frame(width: 600, height: 540)
            .background(Color.neutral1)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.xl))
            .shadow(color: Color.black.opacity(0.15), radius: 40, x: 0, y: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(NSLocalizedString("Delete Record", comment: ""), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("Delete", comment: ""), role: .destructive) { onDelete() }
        } message: {
            Text(NSLocalizedString("This record will be permanently deleted.", comment: ""))
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Inline copy button for detail sections

private struct CopyButton: View {
    @Binding var copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                Text(copied ? NSLocalizedString("Copied", comment: "") : NSLocalizedString("Copy", comment: ""))
                    .font(.system(size: 11, weight: DesignFont.weight_medium))
            }
            .foregroundStyle(copied ? Color.success8 : Color.neutral8)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm)
                    .fill(copied ? Color.success8.opacity(0.1) : Color.neutral3)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xxxxs) {
            Text(label)
                .font(.system(size: DesignFont.xs, weight: DesignFont.weight_semibold))
                .foregroundStyle(Color.neutral7)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: DesignFont.base, weight: DesignFont.weight_semibold, design: .monospaced))
                .foregroundStyle(Color.neutral12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.xxxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .fill(Color.neutral2)
        )
    }
}

// MARK: - Selection action bar

private struct SelectionActionBar: View {
    let selectedCount: Int
    let onMergeAndCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignSpacing.xs) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.primary8)
                    .frame(width: 8, height: 8)
                Text(String(format: NSLocalizedString("%d selected", comment: "Selection count"), selectedCount))
                    .font(.system(size: 13, weight: DesignFont.weight_medium))
                    .foregroundStyle(Color.neutral12)
            }

            Spacer()

            Button(action: onMergeAndCopy) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12))
                    Text(NSLocalizedString("Merge & Copy", comment: "Merge and copy button"))
                        .font(.system(size: 13, weight: DesignFont.weight_semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSpacing.xs)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.sm)
                        .fill(Color.primary8)
                )
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: DesignFont.weight_medium))
                    .foregroundStyle(Color.neutral8)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.neutral3)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSpacing.sm)
        .padding(.vertical, DesignSpacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(Color.neutral1)
                .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .strokeBorder(Color.neutral4, lineWidth: 1)
        )
        .padding(.horizontal, DesignSpacing.lg)
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: DesignSpacing.xxxs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.success8)

            Text(message)
                .font(.system(size: 13, weight: DesignFont.weight_medium))
                .foregroundStyle(Color.neutral12)
        }
        .padding(.horizontal, DesignSpacing.xxs)
        .padding(.vertical, DesignSpacing.xxxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.md)
                .fill(Color.neutral1)
                .shadow(color: Color.neutral9.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }
}
