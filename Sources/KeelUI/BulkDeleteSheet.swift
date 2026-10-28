import KeelCore
import SwiftUI

/// Bulk delete by pattern (FR-SF05, FR-SF06): the typed confirmation with its estimate and Preview matches, then the
/// running job's progress and Cancel, then the report. One model per sheet; the job runs once.
@MainActor
public final class BulkDeleteModel: ObservableObject, Identifiable {
    public enum Stage: Equatable { case confirm, running, finished(BulkDeleteJob.Report) }

    public let job: BulkDeleteJob
    let profile: SafetyProfile
    let database: Int
    @Published public private(set) var stage: Stage = .confirm
    /// The first matches and the estimate; nil while the sample runs.
    @Published public private(set) var sample: BulkDeleteJob.Sample?
    @Published public var showsPreview = false
    @Published public var typed = ""
    /// FR-SF06: batches per second, nil for unthrottled.
    @Published public var throttle: Int? = BulkDeleteJob.defaultThrottle
    @Published public private(set) var progress = BulkDeleteJob.Progress()
    /// Cancel was pressed while running: the button disables until the batch in flight finishes.
    @Published public private(set) var isCancelling = false
    /// The browser refreshes after a run that may have deleted keys.
    let finished: @MainActor () async -> Void

    /// The throttle menu's choices (1–100 batches/s, or unthrottled).
    public static let throttleChoices: [Int?] = [1, 2, 5, 10, 20, 50, 100, nil]

    public init(job: BulkDeleteJob, profile: SafetyProfile, database: Int, finished: @escaping @MainActor () async -> Void = {}) {
        self.job = job; self.profile = profile; self.database = database; self.finished = finished
    }

    /// The typed confirmation, its sentence carrying the sample's count once known.
    public var confirmation: TypedConfirmation {
        let estimate = sample?.estimate
        return BulkDeleteJob.request(for: job.pattern, estimate: estimate, exact: sample?.complete == true, profile: profile, database: database)
    }

    /// Only once the sample is in: the sentence then carries its count, and the sample's SCANs never share the job
    /// connection with the run's.
    public var canConfirm: Bool { stage == .confirm && sample != nil && confirmation.matches(typed) }

    /// Reads the first matches and the database size for the sentence (on the job connection).
    public func loadSample() async {
        guard sample == nil else { return }
        sample = await job.sample()
    }

    /// The destructive button: runs the job with the pattern's yes. Return never gets here (NFR-UX03).
    public func confirm() async {
        guard canConfirm else { return }
        stage = .running
        await job.setThrottle(throttle)
        let report = await job.run(confirmation: BulkDeleteJob.confirmation(for: job.pattern, database: database)) { [weak self] progress in
            Task { @MainActor in
                // Progress hops arrive as separate tasks; never step backwards.
                guard let self, self.stage == .running, progress.elapsed >= self.progress.elapsed else { return }
                self.progress = progress
            }
        }
        progress = report.progress
        stage = .finished(report)
        await finished()
    }

    /// Cancel while running stops after the batch in flight; the sheet then shows the report.
    public func cancel() { job.cancel(); isCancelling = true }

    /// The sheet closed before the run (Cancel, Escape): the sample's connection goes away.
    public func dismissed() async {
        guard stage == .confirm else { return }
        job.cancel()
        await job.close()
    }

    /// "1,221,000 deleted · about a minute left".
    public var progressLine: String { progress.line(estimate: sample?.estimate) }

    static func throttleTitle(_ throttle: Int?) -> String { throttle.map { "\($0) batch\($0 == 1 ? "" : "es")/s" } ?? "Unthrottled" }
}

/// 08 Design → Sheets, boards `BulkDelete` (confirm) and `BulkDeleteDark` (progress). 480 wide; the destructive
/// button has no keyboard shortcut and Return does nothing, so only a click (or VoiceOver's press) confirms.
struct BulkDeleteSheet: View {
    @ObservedObject var model: BulkDeleteModel
    let dismiss: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.stage {
            case .confirm: confirm
            case .running: running
            case .finished(let report): finished(report)
            }
        }
        .padding(.vertical, 28).padding(.horizontal, 32).frame(width: 480)
        .background(Tokens.sheet)
        // Escape mustn't close a running job's sheet: Cancel stops the job and the report follows.
        .interactiveDismissDisabled(model.stage == .running)
        .task { await model.loadSample() }
    }

    @ViewBuilder private var confirm: some View {
        let confirmation = model.confirmation
        title(confirmation.title)
        Text(confirmation.message).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg).fixedSize(horizontal: false, vertical: true)
        if let server = confirmation.serverLine { ProductionServerLine(server: server) }
        preview
        Text(confirmation.prompt).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg)
        TextField("", text: $model.typed).font(Tokens.mono(12.5)).textFieldStyle(.roundedBorder)
            .autocorrectionDisabled().focused($fieldFocused)
            .onSubmit {}
            .accessibilityLabel(confirmation.prompt)
            .onAppear { fieldFocused = true }
        HStack {
            Menu {
                ForEach(BulkDeleteModel.throttleChoices, id: \.self) { choice in
                    Button(BulkDeleteModel.throttleTitle(choice)) { model.throttle = choice }
                }
            } label: {
                Text("Throttle: \(BulkDeleteModel.throttleTitle(model.throttle))")
            }
            .menuStyle(.borderlessButton).fixedSize().font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            .accessibilityLabel("Throttle")
            .accessibilityValue(BulkDeleteModel.throttleTitle(model.throttle))
            .help("At most this many delete batches per second, to protect the server's latency")
            Spacer()
            Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) { Task { await model.confirm() } }
                .tint(Tokens.danger).buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .accessibilityHint(model.canConfirm ? "" : confirmation.prompt)
        }
    }

    /// The optional Preview matches link (first 100), revealed on demand.
    @ViewBuilder private var preview: some View {
        if let sample = model.sample {
            if let failure = sample.failure {
                Text(BulkDeleteModel.sampleFailure(failure)).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true)
            } else if sample.keys.isEmpty {
                Text(sample.complete ? "No keys match right now." : "No matches in the first keys scanned.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            } else if model.showsPreview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(sample.keys.enumerated()), id: \.offset) { _, key in
                            Text(KeyDisplay.name(key)).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8).background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("First \(sample.keys.count) matching keys")
            } else {
                Button("Preview matches") { model.showsPreview = true }
                    .buttonStyle(.plain).foregroundStyle(Tokens.accent).font(Tokens.interface(12))
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Counting matches…").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var running: some View {
        title("Deleting \(KeyDisplay.name(model.job.pattern))")
        Group {
            if let fraction = model.progress.fraction(estimate: model.sample?.estimate) {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear).tint(Tokens.accent)
        .accessibilityLabel("Bulk delete progress")
        Text(model.progressLine).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg).monospacedDigit()
            .accessibilityAddTraits(.updatesFrequently)
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction).disabled(model.isCancelling)
        }
    }

    @ViewBuilder private func finished(_ report: BulkDeleteJob.Report) -> some View {
        title(report.isComplete ? "Bulk delete finished" : report.failure == nil ? "Bulk delete finished with keys left" : "Bulk delete stopped")
        Text(report.summary).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg).fixedSize(horizontal: false, vertical: true)
        Text(report.details).font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
        HStack {
            Spacer()
            Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Tokens.interface(15, weight: .semibold)).foregroundStyle(Tokens.fg).accessibilityAddTraits(.isHeader)
    }

    private func close() {
        Task { await model.dismissed() }
        dismiss()
    }
}

extension BulkDeleteModel {
    /// The sample couldn't be read; the sentence then has no count and the delete still runs on confirmation.
    static func sampleFailure(_ failure: BulkDeleteJob.Failure) -> String {
        switch failure {
        case .cancelled: return "Counting was stopped."
        case .server(let message): return "Counting matches failed: \(message)"
        case .command(let error): return "Counting matches failed (\(error.code))."
        }
    }
}

/// Production: words and the maroon chip together, so the server is never named by color alone (FR-SF03).
struct ProductionServerLine: View {
    let server: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Production").font(Tokens.interface(11, weight: .semibold)).foregroundStyle(Tokens.onProdStrip)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Tokens.prodStrip, in: RoundedRectangle(cornerRadius: 4))
            Text(server).font(Tokens.mono(12)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
