import SwiftUI
import UIKit
import AVFoundation
import Combine

/// Re-runs segmentation and metrics from a corrected event list.
///
/// A protocol rather than a direct call into `AnalysisRunner` so the
/// correction screen can be driven in previews and tests without a video file
/// or a pose model present.
public protocol EventReanalysing: Sendable {
    func reanalyse(sessionID: UUID,
                   events: [EventSnapshot]) async throws -> ReanalysisOutcome
}

public struct ReanalysisOutcome: Sendable {
    public var segmentation: PhaseSegmentation
    public var metricValues: [String: Double]
    public var metricConfidences: [String: Double]

    public init(segmentation: PhaseSegmentation,
                metricValues: [String: Double],
                metricConfidences: [String: Double]) {
        self.segmentation = segmentation
        self.metricValues = metricValues
        self.metricConfidences = metricConfidences
    }
}

// MARK: - Model

/// State for the event correction screen.
///
/// The screen exists because an automatically placed event is a guess with a
/// confidence attached, and a guess that lands two frames late corrupts a
/// contact time by 13 ms with nothing on screen to say so. Confirming by hand
/// takes about a minute per jump and is the single largest improvement
/// available to the repeatability of a squad's data — a confirmed event is
/// identical every time it is read back, where an automatic one moves.
@MainActor
public final class EventCorrectionModel: ObservableObject {

    // MARK: Published state

    @Published public private(set) var events: [EventSnapshot]
    @Published public private(set) var phases: [PhaseSnapshot]
    @Published public private(set) var warnings: [String]
    @Published public var selectedEventID: UUID?
    @Published public private(set) var currentFrame: Int = 0
    @Published public private(set) var isPlaying = false
    @Published public var playbackRate: Float = 1.0
    @Published public private(set) var isReanalysing = false
    @Published public var errorMessage: String?
    @Published public private(set) var hasUnsavedChanges = false

    /// Set when the user is mid-adjustment. The wheel writes here rather than
    /// straight onto the event, so an abandoned adjustment leaves no trace and
    /// scrubbing the wheel does not repeatedly mark the session dirty.
    @Published public var draftFrame: Int?

    public let session: StoredSession
    public let frameCount: Int
    public let frameRate: Double

    /// 2D pose for the skeleton overlay, loaded from the archive.
    @Published public private(set) var poseFrames: [PoseFrame] = []
    @Published public var showSkeleton = true

    private let store: SessionStore
    private let reanalyser: EventReanalysing?
    private var player: AVPlayer?
    private var timeObserver: Any?

    public init(session: StoredSession,
                store: SessionStore,
                reanalyser: EventReanalysing? = nil) {
        self.session = session
        self.store = store
        self.reanalyser = reanalyser
        self.events = session.analysis.events.sorted { $0.timestamp < $1.timestamp }
        self.phases = session.analysis.phases
        self.warnings = session.analysis.warnings
        self.frameCount = max(session.analysis.frameCount, 1)
        // ProcessingTimebase.analysisRate is deliberately not used as the
        // fallback here: it is mutable, set fresh at the start of every
        // analysis run, and so reflects whatever session was analysed most
        // recently rather than anything meaningful to this one.
        // safeDefaultRate is the actual constant — the floor every
        // supported capture mode can reach.
        self.frameRate = session.analysis.measuredFrameRate > 0
            ? session.analysis.measuredFrameRate
            : ProcessingTimebase.safeDefaultRate

        // Open on the first event that needs attention rather than at frame
        // zero. The approach run is the least interesting part of the clip
        // and making the user scrub past it every time is friction that
        // discourages the confirmation step entirely.
        selectedEventID = (events.first(where: \.needsReview) ?? events.first)?.id
        if let event = selectedEvent {
            currentFrame = videoFrame(forTime: event.timestamp)
        }
    }

    /// Load the archived 2D pose so the skeleton can be drawn.
    ///
    /// Failure is silent and non-fatal: the overlay is an aid to judging a
    /// contact, not a prerequisite for it, and a session recorded before the
    /// archive existed should still be correctable.
    public func loadPose() async {
        poseFrames = (try? await store.loadPoseArchive(for: session.id)) ?? []
    }

    /// Pose for the frame currently on screen.
    ///
    /// Matched by timestamp rather than by index. The archive is indexed by
    /// source-video frame, which is the same numbering the player uses, but
    /// a dropped source frame leaves a hole — so a nearest-in-time lookup is
    /// correct where a direct index would silently draw the wrong pose.
    public var currentPoseFrame: PoseFrame? {
        guard !poseFrames.isEmpty else { return nil }
        let target = currentTime
        return poseFrames.min {
            abs($0.timestamp - target) < abs($1.timestamp - target)
        }
    }

    // MARK: Derived

    public var selectedEvent: EventSnapshot? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    public var selectedIndex: Int? {
        guard let id = selectedEventID else { return nil }
        return events.firstIndex { $0.id == id }
    }

    public var confirmedCount: Int { events.filter(\.isManuallyConfirmed).count }
    public var reviewCount: Int { events.filter(\.needsReview).count }
    public var allConfirmed: Bool { !events.isEmpty && confirmedCount == events.count }

    public var currentTime: Double { time(forFrame: currentFrame) }
    public var duration: Double { time(forFrame: frameCount - 1) }

    // Two frame numberings exist and conflating them is the easiest way to
    // corrupt this screen. Everything the user sees and seeks is a *video*
    // frame; everything written back into an event is a *timestamp*, from
    // which the analysis-grid index is recomputed. Timestamps are the only
    // quantity both numberings agree on.

    public func time(forFrame videoFrame: Int) -> Double {
        Double(videoFrame) / frameRate
    }

    public func videoFrame(forTime time: Double) -> Int {
        min(max(Int((time * frameRate).rounded()), 0), frameCount - 1)
    }

    /// Analysis-grid index for a video timestamp, for writing back to events.
    public func analysisIndex(forTime time: Double) -> Int {
        session.analysis.analysisFrameIndex(forTime: time)
    }

    /// The phase covering a moment in time.
    ///
    /// Phase boundaries are stored as analysis-grid indices, so the lookup
    /// converts rather than comparing a video frame against them directly.
    public func phase(atTime time: Double) -> PhaseSnapshot? {
        phases.first { time >= $0.startTime && time <= $0.endTime }
    }

    // MARK: Playback

    public func attach(player: AVPlayer) {
        self.player = player
        // Observe at a quarter of the frame interval so the scrubber and the
        // frame counter stay in step with the picture during playback.
        let interval = CMTime(seconds: 1 / (frameRate * 4),
                              preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval,
                                                      queue: .main) { [weak self] time in
            guard let self, self.isPlaying else { return }
            Task { @MainActor in
                self.currentFrame = self.videoFrame(forTime: time.seconds)
            }
        }
    }

    public func detachPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    public func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            // Land on an exact frame when stopping, so whatever the user
            // pauses on is the frame they can act on.
            seek(toFrame: currentFrame)
        } else {
            player.rate = playbackRate
            isPlaying = true
        }
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    /// Seek exactly. Zero tolerance costs decode time but is non-negotiable
    /// here: an approximate seek lands on the nearest keyframe rather than
    /// the requested time, and `CaptureController` writes one keyframe per
    /// second (`AVVideoMaxKeyFrameIntervalKey` is set to the frame rate), so
    /// a tolerant seek can be off by most of a second — the user would be
    /// confirming an event against a completely different part of the jump.
    public func seek(toFrame frame: Int) {
        let clamped = min(max(frame, 0), frameCount - 1)
        currentFrame = clamped
        let time = CMTime(seconds: self.time(forFrame: clamped),
                          preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func step(by delta: Int) {
        if isPlaying { togglePlayback() }
        seek(toFrame: currentFrame + delta)
    }

    // MARK: Selection

    public func select(_ event: EventSnapshot) {
        if isPlaying { togglePlayback() }
        selectedEventID = event.id
        draftFrame = nil
        seek(toFrame: videoFrame(forTime: event.timestamp))
    }

    public func selectAdjacent(offset: Int) {
        guard !events.isEmpty else { return }
        let index = selectedIndex ?? 0
        let next = min(max(index + offset, 0), events.count - 1)
        select(events[next])
    }

    /// Jump to the next event still awaiting review, wrapping around. This is
    /// the primary way through the screen: the user works the review queue
    /// down rather than stepping through every event in order.
    public func selectNextNeedingReview() {
        let ordered = events
        let start = (selectedIndex ?? -1) + 1
        let rotated = Array(ordered[start...]) + Array(ordered[..<start])
        if let next = rotated.first(where: \.needsReview) {
            select(next)
        }
    }

    // MARK: Editing

    /// Begin an adjustment, seeding the draft with the event's current frame.
    public func beginAdjusting() {
        guard let event = selectedEvent else { return }
        if isPlaying { togglePlayback() }
        draftFrame = videoFrame(forTime: event.timestamp)
    }

    public func cancelAdjusting() {
        draftFrame = nil
        if let event = selectedEvent {
            seek(toFrame: videoFrame(forTime: event.timestamp))
        }
    }

    /// Preview the draft frame in the player without committing it.
    public func previewDraft(_ frame: Int) {
        draftFrame = frame
        seek(toFrame: frame)
    }

    /// Commit the drafted frame onto the selected event and confirm it.
    ///
    /// Committing implies confirmation: a user who has just placed an event
    /// by hand has, by definition, looked at it.
    public func commitAdjustment() {
        guard let draft = draftFrame,
              let index = selectedIndex else { return }
        let timestamp = time(forFrame: draft)
        events[index].timestamp = timestamp
        // Written back on the analysis grid, not the video grid. The
        // segmenter matches events to reconstructed frames by this index.
        events[index].frameIndex = analysisIndex(forTime: timestamp)
        events[index].isManuallyConfirmed = true
        // A hand-placed event is as good as the user's eye, which is the
        // reference this screen exists to apply. Confidence is no longer a
        // statement about the detector's output.
        events[index].confidence = 1.0
        draftFrame = nil
        markDirty()
    }

    public func confirmSelected() {
        guard let index = selectedIndex else { return }
        events[index].isManuallyConfirmed = true
        events[index].confidence = 1.0
        markDirty()
        advanceAfterConfirming()
    }

    public func confirmAllRemaining() {
        for index in events.indices where !events[index].isManuallyConfirmed {
            events[index].isManuallyConfirmed = true
            events[index].confidence = 1.0
        }
        markDirty()
    }

    /// Undo a correction, putting the event back where the detector had it.
    public func revertSelected() {
        guard let index = selectedIndex else { return }
        events[index].frameIndex = events[index].detectedFrameIndex
        events[index].timestamp = events[index].detectedTimestamp
        events[index].isManuallyConfirmed = false
        draftFrame = nil
        markDirty()
        seek(toFrame: videoFrame(forTime: events[index].timestamp))
    }

    public func deleteSelected() {
        guard let index = selectedIndex else { return }
        events.remove(at: index)
        selectedEventID = events.indices.contains(index)
            ? events[index].id
            : events.last?.id
        draftFrame = nil
        markDirty()
    }

    public func changeSelectedSide(to side: GroundEvent.Side) {
        guard let index = selectedIndex else { return }
        events[index].side = side
        events[index].isManuallyConfirmed = true
        markDirty()
    }

    public func changeSelectedType(to type: EventType) {
        guard let index = selectedIndex else { return }
        events[index].type = type
        events[index].isManuallyConfirmed = true
        markDirty()
    }

    /// Add an event the detector missed, at the frame currently on screen.
    public func addEvent(type: EventType, side: GroundEvent.Side) {
        let event = EventSnapshot(type: type,
                                  timestamp: currentTime,
                                  frameIndex: analysisIndex(forTime: currentTime),
                                  side: side,
                                  confidence: 1.0,
                                  isManuallyConfirmed: true,
                                  isUserCreated: true)
        events.append(event)
        events.sort { $0.timestamp < $1.timestamp }
        selectedEventID = event.id
        markDirty()
    }

    private func advanceAfterConfirming() {
        if reviewCount > 0 {
            selectNextNeedingReview()
        } else {
            selectAdjacent(offset: 1)
        }
    }

    private func markDirty() {
        hasUnsavedChanges = true
        // Phases and warnings on screen came from the previous event list, so
        // they are stale the moment an event moves. Clearing them is more
        // honest than leaving numbers that no longer follow from what is
        // shown; the re-analysis fills them back in.
        warnings = ["Events have changed. Re-analyse to update the phases and "
                    + "measurements."]
    }

    // MARK: Persisting

    /// Re-run segmentation and metrics, then write everything back.
    public func reanalyseAndSave() async {
        isReanalysing = true
        defer { isReanalysing = false }

        guard let reanalyser else {
            errorMessage = "Re-analysis is unavailable in this build."
            return
        }

        do {
            let outcome = try await reanalyser.reanalyse(sessionID: session.id,
                                                         events: events)
            try await store.updateAnalysis(id: session.id,
                                           events: events,
                                           segmentation: outcome.segmentation,
                                           metricValues: outcome.metricValues,
                                           metricConfidences: outcome.metricConfidences)
            phases = outcome.segmentation.phases.map(PhaseSnapshot.init)
            warnings = outcome.segmentation.warnings
            hasUnsavedChanges = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Screen

public struct EventCorrectionView: View {

    @StateObject private var model: EventCorrectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showingAddSheet = false
    @State private var showingDeleteConfirmation = false

    public let videoURL: URL?
    public var onFinished: () -> Void

    public init(session: StoredSession,
                store: SessionStore,
                videoURL: URL?,
                reanalyser: EventReanalysing? = nil,
                onFinished: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: EventCorrectionModel(session: session,
                                                                store: store,
                                                                reanalyser: reanalyser))
        self.videoURL = videoURL
        self.onFinished = onFinished
    }

    public var body: some View {
        NavigationStack {
            // Side by side, not stacked. The app is locked to landscape (see
            // Info.plist), where usable height is short — an iPhone gives
            // roughly 340 pt of it once safe areas are subtracted. A video
            // pane stacked above a scrolling control column, as this screen
            // originally was, ate nearly all of that on the video alone.
            // Landscape is also simply the right shape for this: a wide
            // pane for the picture, a column beside it for what you do about
            // what's in it — the layout every video review tool converges
            // on for exactly this reason.
            HStack(spacing: 0) {
                videoPane
                    .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(spacing: 16) {
                        progressSummary
                        EventTimelineView(model: model)
                        if let event = model.selectedEvent {
                            EventDetailPanel(model: model,
                                             event: event,
                                             onDelete: { showingDeleteConfirmation = true })
                        }
                        warningsPane
                        reanalyseButton
                    }
                    .padding()
                }
                .frame(width: 340)
            }
            .navigationTitle("Confirm events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.detachPlayer()
                        onFinished()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add event at this frame", systemImage: "plus.circle")
                        }
                        Button {
                            model.confirmAllRemaining()
                        } label: {
                            Label("Confirm all remaining", systemImage: "checkmark.circle")
                        }
                        .disabled(model.allConfirmed)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { await setUpPlayer() }
            .onDisappear { model.detachPlayer() }
            .sheet(isPresented: $showingAddSheet) {
                AddEventSheet(model: model)
                    .presentationDetents([.height(280)])
            }
            .confirmationDialog("Delete this event?",
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete event", role: .destructive) { model.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The phases either side of it will merge. You can add an event "
                     + "back at any frame.")
            }
            .alert("Could not save",
                   isPresented: .constant(model.errorMessage != nil)) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func setUpPlayer() async {
        await model.loadPose()
        guard let videoURL else { return }
        let player = AVPlayer(url: videoURL)
        // Without this the player rounds seeks to the nearest sync sample and
        // frame-stepping does nothing visible.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        model.attach(player: player)
        model.seek(toFrame: model.currentFrame)
    }

    // MARK: Panes

    @ViewBuilder
    private var videoPane: some View {
        ZStack {
            Color.black
            if let player {
                ZoomableVideoSurface(player: player,
                                    poseFrame: model.currentPoseFrame,
                                    imageSize: videoImageSize,
                                    showSkeleton: model.showSkeleton,
                                    emphasisSide: model.selectedEvent?.side)
            } else {
                missingVideoPlaceholder
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        model.showSkeleton.toggle()
                    } label: {
                        Image(systemName: model.showSkeleton
                              ? "figure.walk" : "figure.walk.motion")
                            .font(.caption)
                            .padding(7)
                            .background(.black.opacity(0.5), in: Circle())
                            .foregroundStyle(model.showSkeleton ? .yellow : .white)
                    }
                    .padding(8)
                    .opacity(model.poseFrames.isEmpty ? 0 : 1)
                }
                Spacer()
                transportControls
            }
        }
    }

    /// Source-video pixel dimensions, which the skeleton overlay needs to map
    /// landmark pixels into view coordinates.
    private var videoImageSize: CGSize {
        CaptureConfiguration.imageSize(
            fromFingerprint: model.session.record.key.captureFingerprint)
    }

    private var missingVideoPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.5))
            Text("Footage for this session is no longer on the device")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
            Text("Events cannot be confirmed without video to check them against. "
                 + "The measurements from the original analysis are unchanged.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            Button { model.step(by: -1) } label: {
                Image(systemName: "backward.frame.fill")
            }
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            Button { model.step(by: 1) } label: {
                Image(systemName: "forward.frame.fill")
            }

            Divider().frame(height: 20).overlay(.white.opacity(0.3))

            ForEach([0.25 as Float, 0.5, 1.0], id: \.self) { rate in
                Button {
                    model.setPlaybackRate(rate)
                } label: {
                    Text(rate == 1.0 ? "1×" : "\(rate == 0.25 ? "¼" : "½")×")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.playbackRate == rate ? .black : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(model.playbackRate == rate ? .white : .clear,
                                    in: Capsule())
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("Frame \(model.currentFrame)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(Format.timecode(model.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55))
        .disabled(player == nil)
    }

    private var progressSummary: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: model.events.isEmpty ? 0
                          : Double(model.confirmedCount) / Double(model.events.count))
                    .stroke(model.allConfirmed ? Color.green : Color.accentColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(model.confirmedCount)/\(model.events.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.allConfirmed ? "All events confirmed"
                                        : "\(model.reviewCount) need a look")
                    .font(.subheadline.weight(.semibold))
                Text(model.allConfirmed
                     ? "This session's timing is now repeatable to about ±7 ms."
                     : "Low-confidence events are marked. Check each against the "
                     + "video and confirm or move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if model.reviewCount > 0 {
                Button("Next") { model.selectNextNeedingReview() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var warningsPane: some View {
        if !model.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var reanalyseButton: some View {
        Button {
            Task { await model.reanalyseAndSave() }
        } label: {
            HStack {
                if model.isReanalysing {
                    ProgressView().controlSize(.small)
                }
                Text(model.isReanalysing ? "Re-analysing" : "Re-analyse with these events")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isReanalysing || !model.hasUnsavedChanges)
    }
}

// MARK: - Timeline

/// Events laid over the phase structure.
///
/// Read-only by design. Dragging a marker on a timeline this dense — a whole
/// jump is under two seconds and adjacent events can sit six frames apart —
/// puts a finger over the very thing being placed and lands wherever the
/// touch happened to lift. Selection happens here; placement happens on the
/// frame picker, where the number is visible and the step is exactly one
/// frame.
struct EventTimelineView: View {

    @ObservedObject var model: EventCorrectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .topLeading) {
                    phaseBands(width: width)

                    // Playhead
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 1.5, height: 64)
                        .offset(x: x(forTime: model.currentTime, width: width))

                    ForEach(model.events) { event in
                        marker(for: event, width: width)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            model.seek(toFrame: Int(fraction * Double(model.frameCount - 1)))
                        }
                )
            }
            .frame(height: 64)

            HStack {
                Text(Format.timecode(0))
                Spacer()
                Text(Format.timecode(model.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// Timeline position from a timestamp.
    ///
    /// Time rather than frame index throughout: the phases carry analysis-grid
    /// indices and the playhead carries a video frame, and the two grids do
    /// not line up. Placing both from their timestamps is the only way they
    /// land where the picture says they should.
    private func x(forTime time: Double, width: CGFloat) -> CGFloat {
        guard model.duration > 1e-9 else { return 0 }
        return CGFloat(time / model.duration) * width
    }

    private func phaseBands(width: CGFloat) -> some View {
        ForEach(model.phases) { phase in
            let start = x(forTime: phase.startTime, width: width)
            let end = x(forTime: phase.endTime, width: width)
            Rectangle()
                .fill(colour(for: phase.phase).opacity(0.28))
                .frame(width: max(end - start, 1), height: 34)
                .offset(x: start, y: 15)
        }
    }

    private func marker(for event: EventSnapshot, width: CGFloat) -> some View {
        let isSelected = event.id == model.selectedEventID
        return VStack(spacing: 2) {
            Image(systemName: event.type == .touchdown
                  ? "arrow.down.to.line" : "arrow.up.from.line")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(markerColour(event), in: Circle())
                .overlay(Circle().stroke(Color.primary,
                                         lineWidth: isSelected ? 2 : 0))
            Rectangle()
                .fill(markerColour(event))
                .frame(width: isSelected ? 2 : 1, height: 40)
        }
        .offset(x: x(forTime: event.timestamp, width: width) - 9)
        .onTapGesture { model.select(event) }
    }

    private func markerColour(_ event: EventSnapshot) -> Color {
        if event.isManuallyConfirmed { return .green }
        if event.needsReview { return .orange }
        return .blue
    }

    private func colour(for phase: JumpPhase) -> Color {
        switch phase {
        case .approach:                            return .gray
        case .hopContact, .stepContact, .jumpContact: return .indigo
        case .hopFlight:                           return .teal
        case .stepFlight:                          return .cyan
        case .jumpFlight:                          return .mint
        case .landing:                             return .gray
        }
    }
}

// MARK: - Detail panel

struct EventDetailPanel: View {

    @ObservedObject var model: EventCorrectionModel
    let event: EventSnapshot
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.draftFrame != nil {
                FramePicker(model: model, event: event)
            } else {
                summaryRows
                actionRow
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let phase = model.phase(atTime: event.timestamp) {
                    Text(phase.phase.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusBadge
        }
    }

    private var title: String {
        let side = event.side == .left ? "Left" : "Right"
        let kind = event.type == .touchdown ? "touchdown" : "toe-off"
        return "\(side) \(kind)"
    }

    private var statusBadge: some View {
        let (text, colour): (String, Color) = {
            if event.isUserCreated { return ("Added by hand", .blue) }
            if event.isManuallyConfirmed && event.isMoved { return ("Moved", .blue) }
            if event.isManuallyConfirmed { return ("Confirmed", .green) }
            if event.needsReview { return ("Needs review", .orange) }
            return ("Automatic", .secondary)
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    private var summaryRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                // The video frame, because that is what the user is looking
                // at. The analysis-grid index the event actually stores is an
                // implementation detail and showing it would only confuse.
                Text("Frame").foregroundStyle(.secondary)
                Text("\(model.videoFrame(forTime: event.timestamp))")
                if event.isMoved {
                    Text("was \(model.videoFrame(forTime: event.detectedTimestamp))")
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Time").foregroundStyle(.secondary)
                Text(Format.timecode(event.timestamp))
                if event.isMoved {
                    Text(Format.signedMilliseconds(
                        event.timestamp - event.detectedTimestamp))
                        .foregroundStyle(.blue)
                }
            }
            if !event.isManuallyConfirmed {
                GridRow {
                    Text("Confidence").foregroundStyle(.secondary)
                    Text(Format.percent(event.confidence * 100, decimals: 0))
                        .foregroundStyle(event.needsReview ? Color.orange : Color.primary)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.confirmSelected()
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(event.isManuallyConfirmed)

                Button {
                    model.beginAdjusting()
                } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Menu {
                    Section("Foot") {
                        Button("Left") { model.changeSelectedSide(to: .left) }
                        Button("Right") { model.changeSelectedSide(to: .right) }
                    }
                    Section("Type") {
                        Button("Touchdown") { model.changeSelectedType(to: .touchdown) }
                        Button("Toe-off") { model.changeSelectedType(to: .toeOff) }
                    }
                } label: {
                    Label("Reclassify", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.revertSelected()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!event.isMoved && !event.isManuallyConfirmed)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Button {
                    model.selectAdjacent(offset: -1)
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .font(.caption)
                }
                Spacer()
                Button {
                    model.selectAdjacent(offset: 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Frame picker

/// Numeric frame picker.
///
/// A wheel over a window of frames either side of where the detector put the
/// event, plus single-frame steppers. Everything here is stated as a number:
/// the absolute frame, the offset from the detection, and the time that
/// offset is worth in milliseconds.
///
/// The millisecond column is the point of the design. One frame is 4.2 ms at
/// 240 fps or 8.3 ms at 120 fps, and the meaningful-change threshold on
/// contact time is 15 ms — so a two- or three-frame correction is the
/// difference between reporting a real change and reporting noise,
/// depending on which mode a session was recorded in. A picker that showed
/// only frame numbers would hide that relationship behind arithmetic the
/// user has to do themselves.
struct FramePicker: View {

    @ObservedObject var model: EventCorrectionModel
    let event: EventSnapshot

    /// How far either side of the detected position the wheel offers,
    /// specified in time rather than frames for the same reason
    /// `ProcessingTimebase`'s filter windows are: a session recorded at
    /// 120 fps and one at 240 fps should offer the same real margin for
    /// error, not a window that is twice as wide in one as the other purely
    /// because the frame count means something different. 250 ms is
    /// comfortably wider than any plausible detector error; beyond that the
    /// event is not misplaced, it is wrong, and the answer is to delete it
    /// and add one where it belongs.
    private let windowMilliseconds: Double = 250

    private var window: Int {
        max(Int(windowMilliseconds / 1000 * model.frameRate), 1)
    }

    /// Centre of the wheel: where the detector originally put the event, as a
    /// video frame.
    private var centre: Int {
        min(max(model.videoFrame(forTime: event.detectedTimestamp), 0),
            model.frameCount - 1)
    }

    private var range: [Int] {
        let lower = max(centre - window, 0)
        let upper = min(centre + window, model.frameCount - 1)
        // A corrupt or partially-written session can carry a timestamp
        // outside the clip, which would invert the range and trap.
        guard lower <= upper else { return [centre] }
        return Array(lower...upper)
    }

    private var draft: Int {
        model.draftFrame ?? model.videoFrame(forTime: event.timestamp)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Place \(event.type == .touchdown ? "touchdown" : "toe-off")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(offsetSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(draft == centre ? Color.secondary : Color.blue)
            }

            Picker("Frame", selection: Binding(
                get: { draft },
                set: { model.previewDraft($0) }
            )) {
                ForEach(range, id: \.self) { frame in
                    HStack(spacing: 10) {
                        Text("\(frame)")
                            .font(.body.monospacedDigit().weight(.medium))
                        Text(offsetLabel(for: frame))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(frame)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)

            HStack(spacing: 12) {
                stepButton(-5, label: "−5")
                stepButton(-1, label: "−1")
                Spacer()
                Text(Format.timecode(model.time(forFrame: draft)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                stepButton(1, label: "+1")
                stepButton(5, label: "+5")
            }

            HStack(spacing: 10) {
                Button("Cancel") { model.cancelAdjusting() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Set and confirm") { model.commitAdjustment() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func stepButton(_ delta: Int, label: String) -> some View {
        Button {
            let next = min(max(draft + delta, range.first ?? 0), range.last ?? 0)
            model.previewDraft(next)
        } label: {
            Text(label)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 40, height: 30)
        }
        .buttonStyle(.bordered)
    }

    private func offsetLabel(for frame: Int) -> String {
        let delta = frame - centre
        if delta == 0 { return "detected" }
        let ms = Double(delta) / model.frameRate * 1000
        return String(format: "%+d fr  %+.0f ms", delta, ms)
    }

    private var offsetSummary: String {
        let delta = draft - centre
        guard delta != 0 else { return "At detected frame" }
        let ms = Double(delta) / model.frameRate * 1000
        return String(format: "%+d frames · %+.0f ms", delta, ms)
    }
}

// MARK: - Add event

struct AddEventSheet: View {

    @ObservedObject var model: EventCorrectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var type: EventType = .touchdown
    @State private var side: GroundEvent.Side = .left

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        Text("Touchdown").tag(EventType.touchdown)
                        Text("Toe-off").tag(EventType.toeOff)
                    }
                    .pickerStyle(.segmented)

                    Picker("Foot", selection: $side) {
                        Text("Left").tag(GroundEvent.Side.left)
                        Text("Right").tag(GroundEvent.Side.right)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("The event is placed at frame \(model.currentFrame) — "
                         + "\(Format.timecode(model.currentTime)). Close this and "
                         + "step the video if that is not the right frame.")
                }
            }
            .navigationTitle("Add event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addEvent(type: type, side: side)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Zoomable video + skeleton

/// The video and its skeleton overlay, pinch-zoomable and pannable as one
/// unit.
///
/// This is the fix for the screen's actual job: judging whether a foot is on
/// the ground in a specific frame. At full frame width a foot is perhaps
/// twenty pixels, and the skeleton overlay helps only if the user can
/// magnify it to check the overlay is right — which is the judgement this
/// screen exists to support. Video and skeleton share one transform rather
/// than being zoomed independently; two independently-zoomed layers would
/// drift apart pixel by pixel and the whole point of drawing the skeleton is
/// that it stays registered to the picture underneath it.
///
/// Double-tap re-centres on the emphasised foot at a fixed useful
/// magnification — the fast path, since checking the foot the correction
/// screen has already selected is what happens on almost every event.
struct ZoomableVideoSurface: View {

    let player: AVPlayer
    let poseFrame: PoseFrame?
    let imageSize: CGSize
    let showSkeleton: Bool
    let emphasisSide: GroundEvent.Side?

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinchDelta: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 6
    private let doubleTapScale: CGFloat = 3.5

    var body: some View {
        GeometryReader { geometry in
            let effectiveScale = scale * pinchDelta
            let effectiveOffset = CGSize(width: offset.width + dragDelta.width,
                                         height: offset.height + dragDelta.height)

            ZStack {
                VideoSurface(player: player)
                if showSkeleton {
                    SkeletonOverlay(frame: poseFrame,
                                    imageSize: imageSize,
                                    emphasisSide: emphasisSide)
                }
            }
            .scaleEffect(effectiveScale)
            .offset(effectiveOffset)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .updating($pinchDelta) { value, state, _ in state = value }
                    .onEnded { value in
                        scale = clampedScale(scale * value)
                        offset = clampedOffset(offset, scale: scale, in: geometry.size)
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($dragDelta) { value, state, _ in
                        // Panning only does something once zoomed in — at
                        // 1x the frame already fills the pane, and letting a
                        // drag move it would just show black bars for no
                        // benefit.
                        guard scale > minimumScale + 0.01 else { return }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard scale > minimumScale + 0.01 else { return }
                        offset = clampedOffset(
                            CGSize(width: offset.width + value.translation.width,
                                   height: offset.height + value.translation.height),
                            scale: scale, in: geometry.size)
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if scale > minimumScale + 0.01 {
                        scale = minimumScale
                        offset = .zero
                    } else {
                        scale = doubleTapScale
                        offset = centredOffset(onFoot: emphasisSide,
                                              scale: scale, in: geometry.size)
                    }
                }
            }
        }
        .clipped()
        // A new selected event resets the view. Without this, zooming to
        // inspect one event would leave every subsequently-selected event
        // magnified into the same corner of the frame, which reads as a
        // stuck or broken picture rather than an intentional zoom.
        .onChange(of: emphasisSide) { _, _ in resetZoom() }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = minimumScale
            offset = .zero
        }
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }

    /// Keep the picture covering the pane — never pan far enough to reveal
    /// black bars past the edge of the actual frame.
    private func clampedOffset(_ value: CGSize,
                               scale: CGFloat,
                               in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    /// Offset that centres the view on the emphasised foot's approximate
    /// position, so the double-tap lands somewhere useful rather than on
    /// whatever happened to be in the middle of the frame.
    private func centredOffset(onFoot side: GroundEvent.Side?,
                               scale: CGFloat,
                               in size: CGSize) -> CGSize {
        guard let side, let poseFrame else { return .zero }
        let landmarks = PoseLandmark.footLandmarks(side: side)
        guard let foot = poseFrame[landmarks.heel] ?? poseFrame[landmarks.toe]
        else { return .zero }

        let mapping = AspectFitMapping(imageSize: imageSize, viewSize: size)
        let point = mapping.viewPoint(fromImage: foot.position)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        // Translation needed to bring `point` to the centre, scaled up by
        // the zoom factor since the offset is applied after scaling.
        let raw = CGSize(width: (centre.x - point.x) * scale,
                         height: (centre.y - point.y) * scale)
        return clampedOffset(raw, scale: scale, in: size)
    }
}

// MARK: - Video surface

/// Thin wrapper over `AVPlayerLayer`.
///
/// `VideoPlayer` from AVKit brings its own transport controls, which cannot be
/// removed and which fight the frame-accurate stepping this screen depends on.
struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
