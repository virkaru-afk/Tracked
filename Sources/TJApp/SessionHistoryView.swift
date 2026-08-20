import SwiftUI

@MainActor
public final class SessionHistoryModel: ObservableObject {

    @Published public private(set) var sessions: [StoredSession] = []
    @Published public var athleteFilter: String?
    @Published public var selectedForComparison: Set<UUID> = []
    @Published public private(set) var droppedVideoNotice: String?

    private let store: SessionStore

    public init(store: SessionStore) {
        self.store = store
    }

    public func load() async {
        // Retention runs here rather than on a timer: this is the screen that
        // lists footage, so it is the one place where a user can be told what
        // was removed at the moment they might look for it.
        if let dropped = try? await store.pruneExpiredVideos(), !dropped.isEmpty {
            droppedVideoNotice = dropped.count == 1
                ? "Footage from 1 trial passed its three-day window and was removed. "
                + "Its measurements are unchanged."
                : "Footage from \(dropped.count) trials passed its three-day window "
                + "and was removed. Their measurements are unchanged."
        }
        sessions = (try? await store.loadAll()) ?? []
    }

    public var athletes: [String] {
        Array(Set(sessions.map(\.athleteName))).sorted()
    }

    public var filtered: [StoredSession] {
        guard let athleteFilter else { return sessions }
        return sessions.filter { $0.athleteName == athleteFilter }
    }

    /// Trials grouped by calendar day, newest day first.
    public var byDay: [(day: Date, trials: [StoredSession])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.date)
        }
        return groups
            .map { (day: $0.key, trials: $0.value.sorted { $0.trialNumber < $1.trialNumber }) }
            .sorted { $0.day > $1.day }
    }

    /// Hop distances over time for the sparkline, oldest first.
    public func series(metric: String) -> [Double] {
        filtered
            .sorted { $0.date < $1.date }
            .compactMap { $0.record.metricValues[metric] }
    }

    public func toggleComparison(_ id: UUID) {
        if selectedForComparison.contains(id) {
            selectedForComparison.remove(id)
        } else {
            // Two at a time. A three-way diff has no natural baseline and the
            // comparison table stops being readable on a phone.
            if selectedForComparison.count == 2 {
                selectedForComparison.removeFirst()
            }
            selectedForComparison.insert(id)
        }
    }

    public var comparisonPair: (current: StoredSession, previous: StoredSession)? {
        let chosen = sessions.filter { selectedForComparison.contains($0.id) }
        guard chosen.count == 2 else { return nil }
        let sorted = chosen.sorted { $0.date > $1.date }
        return (sorted[0], sorted[1])
    }

    public func keepVideo(_ id: UUID) async {
        try? await store.keepVideo(id: id)
        await load()
    }

    public func delete(_ id: UUID) async {
        try? await store.delete(id: id)
        await load()
    }

    public func dismissNotice() { droppedVideoNotice = nil }
}

// MARK: - Screen

public struct SessionHistoryView: View {

    @StateObject private var model: SessionHistoryModel
    @State private var showingComparison = false

    private let store: SessionStore
    private let reanalyser: EventReanalysing?

    public init(store: SessionStore, reanalyser: EventReanalysing? = nil) {
        _model = StateObject(wrappedValue: SessionHistoryModel(store: store))
        self.store = store
        self.reanalyser = reanalyser
    }

    public var body: some View {
        List {
            if let notice = model.droppedVideoNotice {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive.badge.minus")
                            .foregroundStyle(.secondary)
                        Text(notice)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("OK") { model.dismissNotice() }
                            .font(.caption)
                    }
                }
            }

            if model.athletes.count > 1 {
                Section {
                    Picker("Athlete", selection: $model.athleteFilter) {
                        Text("All athletes").tag(String?.none)
                        ForEach(model.athletes, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            }

            if model.athleteFilter != nil {
                trendSection
            }

            ForEach(model.byDay, id: \.day) { group in
                Section {
                    ForEach(group.trials) { trial in
                        NavigationLink {
                            ResultsView(session: trial,
                                        store: store,
                                        reanalyser: reanalyser)
                        } label: {
                            TrialRow(session: trial,
                                     isSelectedForComparison:
                                        model.selectedForComparison.contains(trial.id))
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                model.toggleComparison(trial.id)
                            } label: {
                                Label("Compare", systemImage: "arrow.left.arrow.right")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            if trial.retention.hasVideo,
                               trial.retention != .keptByUser {
                                Button {
                                    Task { await model.keepVideo(trial.id) }
                                } label: {
                                    Label("Keep video", systemImage: "pin")
                                }
                                .tint(.green)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.day.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text("\(group.trials.count) "
                             + (group.trials.count == 1 ? "trial" : "trials"))
                    }
                }
            }

            if model.sessions.isEmpty {
                ContentUnavailableView("No trials yet",
                                       systemImage: "figure.jumprope",
                                       description: Text("Recorded jumps appear here "
                                                         + "once they have been analysed."))
            }
        }
        .navigationTitle("History")
        .task { await model.load() }
        .safeAreaInset(edge: .bottom) {
            if model.selectedForComparison.count == 2 {
                compareBar
            }
        }
        .sheet(isPresented: $showingComparison) {
            if let pair = model.comparisonPair {
                ComparisonSheet(current: pair.current, previous: pair.previous)
            }
        }
    }

    private var trendSection: some View {
        Section("Hop distance trend") {
            let series = model.series(metric: "Hop distance")
            if series.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Sparkline(values: series)
                        .frame(height: 44)
                    HStack {
                        Text(Imperial.feetInches(series.first ?? 0))
                        Spacer()
                        Text("\(series.count) trials")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Imperial.feetInches(series.last ?? 0))
                    }
                    .font(.caption2.monospacedDigit())
                }
                .padding(.vertical, 4)
            } else {
                Text("At least two analysed trials are needed to show a trend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compareBar: some View {
        Button {
            showingComparison = true
        } label: {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                Text("Compare the 2 selected trials")
                Spacer()
                Button("Clear") { model.selectedForComparison.removeAll() }
                    .font(.caption)
            }
            .padding()
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trial row

/// One trial, with its headline numbers on the row itself.
///
/// The numbers are here rather than one tap deeper because the comparison a
/// coach makes most often is between two trials in the same session, and that
/// comparison is only quick if both numbers are on screen together. A list of
/// dates that must each be opened to see a distance turns a five-second scan
/// into a minute of navigation.
struct TrialRow: View {

    let session: StoredSession
    let isSelectedForComparison: Bool

    private var hop: Double? { session.record.metricValues["Hop distance"] }
    private var step: Double? { session.record.metricValues["Step distance"] }
    private var contact: Double? { session.record.metricValues["Contact time"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Trial \(session.trialNumber)")
                    .font(.subheadline.weight(.semibold))
                if session.eventsConfirmed {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if isSelectedForComparison {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
                retentionIcon
                Text(session.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                numberCell("HOP", hop.map { Imperial.feetInches($0) })
                numberCell("STEP", step.map { Imperial.feetInches($0) })
                numberCell("CONTACT", contact.map { Format.milliseconds($0) })
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }

    private func numberCell(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    @ViewBuilder
    private var retentionIcon: some View {
        switch session.retention {
        case .keptByUser:
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(.green)
        case .temporary(let expiry):
            let days = RetentionPolicy.daysRemaining(until: expiry)
            Text("\(days)d")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(days <= RetentionPolicy.warnWithinDays
                                 ? Color.orange : Color.secondary)
        case .dropped, .unavailable:
            Image(systemName: "film.stack")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Comparison sheet

public struct ComparisonSheet: View {

    public let current: StoredSession
    public let previous: StoredSession

    @Environment(\.dismiss) private var dismiss
    @State private var comparisons: [TrendAnalyser.Comparison] = []
    @State private var refusalReason: String?

    public init(current: StoredSession, previous: StoredSession) {
        self.current = current
        self.previous = previous
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        columnHeader(previous, label: "Earlier")
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Spacer()
                        columnHeader(current, label: "Later")
                    }
                    .padding(.vertical, 4)
                }

                if let refusalReason {
                    Section {
                        Label(refusalReason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(MetricCatalog.Group.allCases, id: \.self) { group in
                        let rows = comparisons.compactMap { comparison -> (TrendAnalyser.Comparison, MetricCatalog.Definition)? in
                            guard let definition = MetricCatalog.definition(for: comparison.metricName),
                                  definition.group == group else { return nil }
                            return (comparison, definition)
                        }
                        .sorted { $0.1.order < $1.1.order }

                        if !rows.isEmpty {
                            Section(group.title) {
                                ForEach(rows, id: \.0.metricName) { comparison, definition in
                                    ComparisonRow(comparison: comparison,
                                                  definition: definition)
                                }
                            }
                        }
                    }

                    if !current.eventsConfirmed || !previous.eventsConfirmed {
                        Section {
                            Label("One or both trials have unconfirmed events. "
                                  + "Differences smaller than about 15 ms in timing "
                                  + "are not distinguishable until both are confirmed.",
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .navigationTitle("Comparison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { compare() }
        }
    }

    private func compare() {
        do {
            comparisons = try TrendAnalyser().compare(current: current.record,
                                                      previous: previous.record)
        } catch {
            refusalReason = error.localizedDescription
        }
    }

    private func columnHeader(_ session: StoredSession, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(session.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption.weight(.medium))
            Text("Trial \(session.trialNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ComparisonRow: View {

    let comparison: TrendAnalyser.Comparison
    let definition: MetricCatalog.Definition

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.displayName)
                .font(.subheadline)

            HStack(spacing: 10) {
                Text(MetricCatalog.format(comparison.previousValue,
                                          unit: definition.unit))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(MetricCatalog.format(comparison.currentValue,
                                          unit: definition.unit))
                    .fontWeight(.semibold)
                Spacer()
                ChangeChip(comparison: comparison, definition: definition)
            }
            .font(.caption.monospacedDigit())

            if !comparison.isMeaningful {
                Text(comparison.interpretation)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sparkline

/// Minimal trend line.
///
/// Deliberately unlabelled beyond its endpoints. At the sample sizes here — a
/// handful of trials — a full chart with gridlines invites reading a trend
/// into three points, and the honest signal is the shape plus the two numbers
/// either side of it.
struct Sparkline: View {

    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let span = max(maximum - minimum, 1e-9)

            ZStack {
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = values.count > 1
                            ? width * CGFloat(index) / CGFloat(values.count - 1)
                            : width / 2
                        let y = height - CGFloat((value - minimum) / span) * height
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                if let last = values.last {
                    let y = height - CGFloat((last - minimum) / span) * height
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .position(x: width, y: y)
                }
            }
        }
    }
}
