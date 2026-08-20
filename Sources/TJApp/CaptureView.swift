import SwiftUI
import AVFoundation

/// Record a jump, then analyse it.
///
/// The screen deliberately does not let the user browse away mid-analysis.
/// Pose extraction over a 120–240 fps clip is tens of seconds of work holding
/// a video reader and a model open; letting the view be torn down underneath it
/// invites a half-written session on disk, and a half-written session is
/// worse than none — it appears in history looking analysable.
public struct CaptureView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .framing
    @State private var progress: AnalysisRunner.AnalysisProgress?
    @State private var completedSession: StoredSession?
    @State private var errorMessage: String?
    @State private var elapsed: Double = 0
    @State private var recordingStart: Date?

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    enum Phase: Equatable {
        case framing, recording, analysing, finished
    }

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: state.captureController.session)
                .ignoresSafeArea()

            FramingGuides()
                .ignoresSafeArea()
                .opacity(phase == .framing ? 1 : 0.3)

            VStack {
                topBar
                Spacer()
                if phase == .analysing {
                    analysisPane
                } else {
                    bottomControls
                }
            }
        }
        .task {
            // Re-applies the selected profile's calibrated focus position
            // before the session starts. See `AppState.prepareCaptureSession`.
            state.prepareCaptureSession()
            state.captureController.startRunning()
        }
        .onDisappear {
            state.captureController.stopRunning()
        }
        .onReceive(timer) { _ in
            if let recordingStart {
                elapsed = Date().timeIntervalSince(recordingStart)
            }
        }
        .alert("Could not record", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $completedSession) { session in
            correctionFlow(for: session)
        }
    }

    // MARK: Panes

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .disabled(phase == .recording || phase == .analysing)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let configuration = state.captureConfiguration {
                    Text(configuration.displayName)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                if let profile = state.selectedProfile {
                    Text(profile.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let warning = state.captureController.thermalWarning {
                    Label(warning, systemImage: "thermometer.high")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 200, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding()
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if phase == .framing {
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("Athlete name", text: $state.athleteName)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .submitLabel(.done)
                }
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 40)

                Text("Start recording before the approach begins, and keep the athlete "
                     + "in frame from the last few strides through the landing.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if phase == .recording {
                Text(String(format: "%.1f s", elapsed))
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.bold))
                    .foregroundStyle(.red)
            }

            Button {
                phase == .recording ? stopRecording() : startRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    if phase == .recording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(!state.canRecord)

            if !state.canRecord {
                Text(state.readiness.detail)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(.bottom, 30)
    }

    private var analysisPane: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress?.fraction ?? 0)
                .tint(.white)
                .frame(width: 220)
            Text(progress?.stage ?? "Analysing")
                .font(.subheadline)
                .foregroundStyle(.white)
            Text("Tracking every frame of the jump. This takes about as long as the "
                 + "recording did.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.bottom, 60)
    }

    @ViewBuilder
    private func correctionFlow(for session: StoredSession) -> some View {
        if let store = state.sessionStore {
            CorrectionLoader(session: session,
                             store: store,
                             reanalyser: state.analysisRunner) {
                completedSession = nil
                Task { await state.refreshSessions() }
                dismiss()
            }
        }
    }

    // MARK: Actions

    private func startRecording() {
        guard let store = state.sessionStore else { return }
        Task {
            do {
                // Reserved against a throwaway id: the real session id is
                // minted by the analyser once there is something worth
                // storing, so an abandoned recording leaves no session file
                // behind.
                let (url, _) = await store.reserveVideoURL(for: UUID())
                try state.captureController.startRecording(to: url)
                recordingStart = Date()
                elapsed = 0
                phase = .recording
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        recordingStart = nil
        phase = .analysing
        Task {
            do {
                let clip = try await state.captureController.stopRecording()
                let session = await state.analyse(clip: clip) { update in
                    Task { @MainActor in progress = update }
                }
                if let session {
                    completedSession = session
                    phase = .finished
                } else {
                    errorMessage = state.startupError
                        ?? "The recording could not be analysed."
                    state.startupError = nil
                    phase = .framing
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .framing
            }
        }
    }
}

/// Framing aids.
///
/// The runway line and the board marker are not decoration: the solver
/// assumes the camera is roughly perpendicular to the runway and level with
/// the middle of the board, and a user with nothing to aim at reliably drifts
/// off both. Getting within a few degrees by eye is enough, but only if there
/// is something to be within a few degrees *of*.
struct FramingGuides: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                // Horizontal thirds: keep the runway on the lower line.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 2 / 3))
                    path.addLine(to: CGPoint(x: width, y: height * 2 / 3))
                }
                .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))

                // Vertical centre: put the board here.
                Path { path in
                    path.move(to: CGPoint(x: width / 2, y: height * 0.45))
                    path.addLine(to: CGPoint(x: width / 2, y: height * 0.85))
                }
                .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))

                Text("board")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .position(x: width / 2, y: height * 0.88)
            }
        }
        .allowsHitTesting(false)
    }
}
