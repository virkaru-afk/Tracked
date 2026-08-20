import SwiftUI

/// What the results screen is being compared against.
///
/// Comparison is a control on the results screen rather than a separate
/// destination. The number a coach wants is almost never the absolute one —
/// it is whether this trial beat the last one — and putting that behind a
/// second navigation step means it gets looked at at the end of the session
/// instead of between trials, which is when it could still change something.
public enum ComparisonBasis: Hashable, Sendable {
    case none
    /// The trial immediately before this one, same athlete, same day.
    case previousTrial
    /// The last trial from any earlier day.
    case lastSession
    /// The athlete's furthest hop on this calibration profile.
    case personalBest
    case specific(UUID)

    public var title: String {
        switch self {
        case .none:          return "No comparison"
        case .previousTrial: return "Previous trial"
        case .lastSession:   return "Last session"
        case .personalBest:  return "Best on this profile"
        case .specific:      return "Selected trial"
        }
    }
}

@MainActor
public final class ResultsModel: ObservableObject {

    @Published public private(set) var session: StoredSession
    @Published public private(set) var metrics: [PresentedMetric] = []
    @Published public private(set) var comparisons: [String: TrendAnalyser.Comparison] = [:]
    @Published public private(set) var comparisonSession: StoredSession?
    @Published public private(set) var comparisonError: String?
    @Published public var basis: ComparisonBasis = .previousTrial {
        didSet { Task { await loadComparison() } }
    }
    @Published public private(set) var candidates: [StoredSession] = []

    private let store: SessionStore

    public init(session: StoredSession, store: SessionStore) {
        self.session = session
        self.store = store
        self.metrics = PresentedMetric.from(record: session.record)
    }

    public func load() async {
        candidates = ((try? await store.loadAll()) ?? [])
            .filter { $0.id != session.id && $0.athleteName == session.athleteName }
        await loadComparison()
    }

    /// Refresh after the event correction screen has written new numbers.
    public func reload() async {
        guard let updated = try? await store.load(id: session.id) else { return }
        session = updated
        metrics = PresentedMetric.from(record: updated.record)
        await loadComparison()
    }

    private func loadComparison() async {
        comparisonError = nil
        comparisons = [:]

        guard let other = resolveComparisonSession() else {
            comparisonSession = nil
            return
        }
        comparisonSession = other

        do {
            let results = try TrendAnalyser().compare(current: session.record,
                                                      previous: other.record)
            comparisons = Dictionary(uniqueKeysWithValues:
                                        results.map { ($0.metricName, $0) })
        } catch {
            // A refusal to compare is information, not a failure. Two profiles
            // are two different rulers and the reason belongs on screen.
            comparisonError = error.localizedDescription
        }
    }

    private func resolveComparisonSession() -> StoredSession? {
        let calendar = Calendar.current
        switch basis {
        case .none:
            return nil
        case .previousTrial:
            return candidates
                .filter { calendar.isDate($0.date, inSameDayAs: session.date)
                          && $0.date < session.date }
                .max { $0.date < $1.date }
        case .lastSession:
            return candidates
                .filter { !calendar.isDate($0.date, inSameDayAs: session.date)
                          && $0.date < session.date }
                .max { $0.date < $1.date }
        case .personalBest:
            return candidates
                .filter { $0.record.key.calibrationProfileID
                          == session.record.key.calibrationProfileID }
                .max { ($0.record.metricValues["Hop distance"] ?? 0)
                       < ($1.record.metricValues["Hop distance"] ?? 0) }
        case .specific(let id):
            return candidates.first { $0.id == id }
        }
    }

    public func comparison(for name: String) -> TrendAnalyser.Comparison? {
        comparisons[name]
    }

    public func metrics(in group: MetricCatalog.Group) -> [PresentedMetric] {
        metrics.filter { $0.definition.group == group }
    }
}

// MARK: - Screen

public struct ResultsView: View {

    @StateObject private var model: ResultsModel
    @State private var showingCorrection = false
    @State private var showingFullAnalysis = false

    private let store: SessionStore
    private let reanalyser: EventReanalysing?

    public init(session: StoredSession,
                store: SessionStore,
                reanalyser: EventReanalysing? = nil) {
        _model = StateObject(wrappedValue: ResultsModel(session: session, store: store))
        self.store = store
        self.reanalyser = reanalyser
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                comparisonPicker
                confirmationBanner
                videoRetentionBanner
                warningsCard

                metricGroup(.distances)
                metricGroup(.placement)
                metricGroup(.timing)

                DisclosureGroup("Full analysis", isExpanded: $showingFullAnalysis) {
                    VStack(spacing: 16) {
                        metricGroup(.technique, showHeader: false)
                        reliabilityNote
                        provenanceCard
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                .padding(14)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("\(model.session.athleteName) · Trial \(model.session.trialNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .sheet(isPresented: $showingCorrection) {
            correctionSheet
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.session.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 20) {
                ForEach(model.metrics(in: .distances)
                    .filter { $0.definition.unit == .distanceLarge }) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.definition.displayName.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(metric.formattedValue)
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        changeLabel(for: metric)
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Comparison control

    private var comparisonPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Compare against", selection: $model.basis) {
                Text("Prev trial").tag(ComparisonBasis.previousTrial)
                Text("Last session").tag(ComparisonBasis.lastSession)
                Text("Best").tag(ComparisonBasis.personalBest)
                Text("Off").tag(ComparisonBasis.none)
            }
            .pickerStyle(.segmented)

            if let other = model.comparisonSession {
                Text("Compared with \(other.date.formatted(date: .abbreviated, time: .shortened))"
                     + " · trial \(other.trialNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.basis != .none {
                Text("No earlier trial available for this comparison.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = model.comparisonError {
                Label(error, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var confirmationBanner: some View {
        if !model.session.eventsConfirmed {
            Button {
                showingCorrection = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.tap.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Events not yet confirmed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(model.session.canCorrectEvents
                             ? "About a minute of checking takes timing from roughly "
                             + "±15 ms to ±7 ms, and makes this trial directly "
                             + "comparable to every other confirmed one."
                             : "Footage has been dropped, so events can no longer be "
                             + "checked against video. The measurements stand as "
                             + "analysed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.session.canCorrectEvents {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .background(Color.orange.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!model.session.canCorrectEvents)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Events confirmed — timing accurate to about ±7 ms")
                    .font(.caption)
                Spacer()
                if model.session.canCorrectEvents {
                    Button("Review") { showingCorrection = true }
                        .font(.caption)
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var videoRetentionBanner: some View {
        if case .temporary(let expiry) = model.session.retention {
            let days = RetentionPolicy.daysRemaining(until: expiry)
            if days <= RetentionPolicy.warnWithinDays {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(days == 0 ? "Footage is dropped today"
                                       : "Footage is dropped tomorrow")
                            .font(.caption.weight(.semibold))
                        Text("The measurements are kept permanently either way.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Keep") {
                        Task { try? await store.keepVideo(id: model.session.id)
                               await model.reload() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var warningsCard: some View {
        if !model.session.analysis.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.session.analysis.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Metric groups

    @ViewBuilder
    private func metricGroup(_ group: MetricCatalog.Group,
                             showHeader: Bool = true) -> some View {
        let items = model.metrics(in: group)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if showHeader {
                    HStack {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(items.first?.definition.tier.label ?? "")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(items) { metric in
                    MetricRow(metric: metric,
                              comparison: model.comparison(for: metric.definition.name))
                    if metric.id != items.last?.id { Divider() }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func changeLabel(for metric: PresentedMetric) -> some View {
        if let comparison = model.comparison(for: metric.definition.name) {
            ChangeChip(comparison: comparison, definition: metric.definition)
        }
    }

    // MARK: Notes

    private var reliabilityNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About these numbers", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            Text(MetricCatalog.Tier.indicative.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Joint angles are additionally affected by about 10% by lateral "
                 + "motion — arm swing and trunk drift — which a single camera "
                 + "cannot resolve.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The jump phase is not measured. It lands in the pit, where the "
                 + "foot is occluded and the landing is a slide rather than a "
                 + "plant, so there is no stationary contact to measure from. "
                 + "Phase shares are of hop plus step.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Provenance", systemImage: "shippingbox")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Text("\(model.session.record.key.measuredFrameRate) fps")
                }
                GridRow {
                    Text("Capture mode").foregroundStyle(.secondary)
                    Text(model.session.record.key.captureFingerprint)
                }
                GridRow {
                    Text("Pipeline").foregroundStyle(.secondary)
                    Text(model.session.record.key.pipelineVersion)
                }
                GridRow {
                    Text("Frames").foregroundStyle(.secondary)
                    Text("\(model.session.analysis.frameCount)")
                }
            }
            .font(.caption2.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var correctionSheet: some View {
        CorrectionLoader(session: model.session,
                         store: store,
                         reanalyser: reanalyser) {
            showingCorrection = false
            Task { await model.reload() }
        }
    }
}

/// Resolves the video URL off the store actor before presenting the
/// correction screen.
struct CorrectionLoader: View {

    let session: StoredSession
    let store: SessionStore
    let reanalyser: EventReanalysing?
    let onFinished: () -> Void

    @State private var videoURL: URL?
    @State private var resolved = false

    var body: some View {
        Group {
            if resolved {
                EventCorrectionView(session: session,
                                    store: store,
                                    videoURL: videoURL,
                                    reanalyser: reanalyser,
                                    onFinished: onFinished)
            } else {
                ProgressView()
            }
        }
        .task {
            videoURL = await store.videoURL(for: session)
            resolved = true
        }
    }
}

// MARK: - Rows

struct MetricRow: View {

    let metric: PresentedMetric
    let comparison: TrendAnalyser.Comparison?
    @State private var showingExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.definition.displayName)
                    .font(.subheadline)
                Button {
                    showingExplanation.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(metric.formattedValue)
                    .font(.body.monospacedDigit().weight(.semibold))

                if let comparison {
                    ChangeChip(comparison: comparison, definition: metric.definition)
                }
            }

            if showingExplanation {
                Text(metric.definition.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let threshold = MetricCatalog.thresholdDescription(
                    for: metric.definition.name) {
                    Text(threshold)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The change chip.
///
/// Shows a number only when the change clears the metric's validated noise
/// floor. Below that it says so in words rather than printing a small
/// difference in grey — a greyed-out "+0.3″" still reads as movement, and the
/// entire point of the threshold is that it is not.
struct ChangeChip: View {

    let comparison: TrendAnalyser.Comparison
    let definition: MetricCatalog.Definition

    var body: some View {
        if comparison.isMeaningful {
            HStack(spacing: 3) {
                Image(systemName: comparison.change >= 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text(MetricCatalog.formatChange(comparison.change,
                                                unit: definition.unit)
                        .replacingOccurrences(of: "+", with: "")
                        .replacingOccurrences(of: "−", with: ""))
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
        } else {
            Text("no change")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
    }

    private var tint: Color {
        guard let higherIsBetter = definition.higherIsBetter else { return .blue }
        let improved = higherIsBetter ? comparison.change > 0 : comparison.change < 0
        return improved ? .green : .red
    }
}
