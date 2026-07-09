/**
 * AnalyticsView
 *
 * Usage statistics for transcription sessions.
 * Follows xisper-swiftui-complete.pen design: toolbar + 5 stat cards + chart.
 */

import SwiftData
import SwiftUI

enum AnalyticsPeriod: String, CaseIterable {
    case today = "today"
    case week = "week"
    case total = "total"
    
    var label: String {
        switch self {
        case .today: NSLocalizedString("Today", comment: "")
        case .week:  NSLocalizedString("Week", comment: "")
        case .total: NSLocalizedString("All Time", comment: "")
        }
    }
}

struct AnalyticsView: View {
    @Query private var records: [TranscribeRecord]
    @State private var selectedPeriod: AnalyticsPeriod = .today

    private var filteredRecords: [TranscribeRecord] {
        let cal = Calendar.current
        let start: Date
        switch selectedPeriod {
        case .today:
            start = cal.startOfDay(for: Date())
        case .week:
            start = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .total:
            start = records.first?.createdAt ?? Date()
        }
        return records.filter { $0.createdAt >= start }
    }

    private var totalDuration: TimeInterval {
        filteredRecords.reduce(0) { $0 + $1.duration }
    }

    private var totalChars: Int {
        filteredRecords.reduce(0) { $0 + $1.transcribeContent.count }
    }

    private var timeSaved: TimeInterval {
        totalDuration * 1.5
    }

    private var avgCPM: Int {
        guard totalDuration > 0 else { return 0 }
        return Int((Double(totalChars) / totalDuration) * 60)
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        if secs < 60  { return String(format: "%.0fs", secs) }
        if secs < 3600 { return String(format: "%dm %ds", Int(secs) / 60, Int(secs) % 60) }
        return String(format: "%dh %dm", Int(secs) / 3600, (Int(secs) % 3600) / 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: NSLocalizedString("Analytics", comment: "")) {
                HStack(spacing: 4) {
                    ForEach(AnalyticsPeriod.allCases, id: \.self) { period in
                        Button {
                            withAnimation(.fast) { selectedPeriod = period }
                        } label: {
                            Text(period.label)
                                .font(.system(size: DesignFont.sm, weight: .medium))
                                .foregroundStyle(selectedPeriod == period ? Color.onPrimary : Color.neutral8)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignRadius.sm)
                                        .fill(selectedPeriod == period ? Color.primary8 : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: DesignRadius.md).fill(Color.neutral3))
                .frame(height: 36)
            }
            Divider()
            ScrollView {
                VStack(spacing: DesignSpacing.xxs) {
                    // 5 stat cards — pen: gap $spacing-sm, height 120
                    HStack(spacing: DesignSpacing.xxs) {
                        StatCard(
                            icon: "clock",
                            iconColor: Color.primary8,
                            value: formatDuration(totalDuration),
                            label: NSLocalizedString("Total Speaking Time", comment: "")
                        )
                        StatCard(
                            icon: "character.textbox",
                            iconColor: Color.warning8,
                            value: formatCompactNumber(totalChars),
                            label: NSLocalizedString("Total Characters", comment: "")
                        )
                        StatCard(
                            icon: "timer",
                            iconColor: Color.success8,
                            value: formatDuration(timeSaved),
                            label: NSLocalizedString("Time Saved", comment: "")
                        )
                        StatCard(
                            icon: "gauge.with.dots.needle.67percent",
                            iconColor: Color.warning8,
                            value: "\(avgCPM)",
                            label: NSLocalizedString("Avg CPM", comment: "")
                        )
                        StatCard(
                            icon: "number",
                            iconColor: Color.neutral8,
                            value: "\(filteredRecords.count)",
                            label: NSLocalizedString("Total Records", comment: "")
                        )
                    }

                    // Chart — pen: radius-xl, shadow, padding md
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
                            HStack {
                                Text(NSLocalizedString("Weekly Overview", comment: ""))
                                    .font(.system(size: 18, weight: DesignFont.weight_semibold))
                                    .foregroundStyle(Color.neutral12)
                                Spacer()
                                HStack(spacing: 12) {
                                    ChartLegendDot(color: Color.primary8, label: NSLocalizedString("Speaking Time", comment: "Chart legend"))
                                    ChartLegendDot(color: Color.warning8, label: NSLocalizedString("Characters", comment: "Chart legend"))
                                }
                            }

                            WeeklyBarChart(records: records)
                                .frame(height: 300)
                                .padding(DesignSpacing.xxs)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignRadius.md)
                                        .fill(Color.neutral3)
                                )
                        }
                        .padding(DesignSpacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.xl)
                                .fill(Color.neutral2)
                                .shadow(color: Color.neutral9.opacity(0.05), radius: 12, x: 0, y: 4)
                        )
                    }
                }
                .padding(DesignSpacing.xs)
            }
            .background(Color.neutral1)
        }
    }

    private func formatCompactNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000)
        }
        return "\(num)"
    }
}

// MARK: - Stat Card — pen: radius-lg, shadow, height 120, padding md, gap xs

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)

            Text(value)
                .font(.system(size: 28, weight: DesignFont.weight_semibold))
                .foregroundStyle(Color.neutral12)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(.system(size: 12, weight: DesignFont.weight_medium))
                .foregroundStyle(Color.neutral9)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 120)
        .padding(DesignSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(Color.neutral2)
                .shadow(color: Color.neutral9.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
}

// MARK: - Weekly grouped bar chart (Speaking Time + Characters)

private struct WeeklyBarChart: View {
    let records: [TranscribeRecord]

    private struct DayData: Identifiable {
        let id: String
        let label: String
        let durationMin: Double
        let characters: Int
        let isToday: Bool
    }

    private var dailyData: [DayData] {
        let cal = Calendar.current
        return (0..<7).reversed().map { daysAgo in
            let date = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            let start = cal.startOfDay(for: date)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let dayRecords = records.filter { $0.createdAt >= start && $0.createdAt < end }
            let label = daysAgo == 0 ? NSLocalizedString("Today", comment: "") : cal.shortWeekdaySymbols[cal.component(.weekday, from: date) - 1]
            return DayData(
                id: "\(daysAgo)",
                label: label,
                durationMin: dayRecords.reduce(0.0) { $0 + $1.duration } / 60.0,
                characters: dayRecords.reduce(0) { $0 + $1.transcribeContent.count },
                isToday: daysAgo == 0
            )
        }
    }

    var body: some View {
        let data = dailyData
        let maxDur = max(data.map(\.durationMin).max() ?? 1.0, 1.0)
        let maxChars = max(data.map(\.characters).max() ?? 1, 1)
        let durTicks = axisTicks(maxValue: Int(ceil(maxDur)))
        let charTicks = axisTicks(maxValue: maxChars)

        HStack(alignment: .bottom, spacing: 8) {
            // Left Y-axis: Speaking Time (min)
            AxisLabels(ticks: durTicks, suffix: "m", color: Color.primary8.opacity(0.6), alignment: .trailing)
                .frame(width: 30)

            HStack(spacing: 6) {
                ForEach(data) { day in
                    GroupedBarColumn(
                        label: day.label,
                        durationMin: day.durationMin,
                        characters: day.characters,
                        maxDur: maxDur,
                        maxChars: maxChars,
                        isToday: day.isToday
                    )
                }
            }

            // Right Y-axis: Characters
            AxisLabels(ticks: charTicks, suffix: "", color: Color.warning8.opacity(0.6), alignment: .leading, compact: true)
                .frame(width: 34)
        }
    }

    private func axisTicks(maxValue: Int) -> [Int] {
        let step = max(1, Int(ceil(Double(maxValue) / 4.0)))
        let top = step * 4
        return stride(from: top, through: 0, by: -step).map { $0 }
    }
}

// MARK: - Y-axis labels

private struct AxisLabels: View {
    let ticks: [Int]
    let suffix: String
    let color: Color
    var alignment: HorizontalAlignment = .trailing
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { idx, tick in
                Text(compact ? formatCompact(tick) + suffix : "\(tick)" + suffix)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
                if idx < ticks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, 22)
        .padding(.top, 2)
    }

    private func formatCompact(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.0fK", Double(n) / 1000.0) }
        return "\(n)"
    }
}

// MARK: - Grouped bar column (speaking time + characters side by side)

private struct GroupedBarColumn: View {
    let label: String
    let durationMin: Double
    let characters: Int
    let maxDur: Double
    let maxChars: Int
    let isToday: Bool

    @State private var isHovered = false
    private let maxBarHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 0)

            if isHovered && (durationMin > 0 || characters > 0) {
                VStack(spacing: 2) {
                    if durationMin > 0 {
                        Text(String(format: "%.1fm", durationMin))
                            .foregroundStyle(Color.primary8)
                    }
                    if characters > 0 {
                        Text(formatCompact(characters))
                            .foregroundStyle(Color.warning8)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.xs)
                        .fill(Color.neutral2)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignRadius.xs)
                                .strokeBorder(Color.neutral3, lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(alignment: .bottom, spacing: 3) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 5, bottomLeadingRadius: 2,
                    bottomTrailingRadius: 2, topTrailingRadius: 5
                )
                .fill(isToday ? Color.primary8 : Color.primary8.opacity(0.2))
                .frame(width: 24, height: max(4, durationMin / maxDur * maxBarHeight))

                UnevenRoundedRectangle(
                    topLeadingRadius: 5, bottomLeadingRadius: 2,
                    bottomTrailingRadius: 2, topTrailingRadius: 5
                )
                .fill(isToday ? Color.warning8 : Color.warning8.opacity(0.2))
                .frame(width: 24, height: max(4, Double(characters) / Double(maxChars) * maxBarHeight))
            }

            Text(label)
                .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.primary8 : Color.neutral8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovering in
            withAnimation(.fast) { isHovered = hovering }
        }
    }

    private func formatCompact(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000.0) }
        return "\(n)"
    }
}

// MARK: - Chart legend dot

private struct ChartLegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.neutral8)
        }
    }
}
