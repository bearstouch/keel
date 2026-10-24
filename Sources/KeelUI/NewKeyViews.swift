import KeelCore
import SwiftUI

/// New Key… (⇧⌘N, FR-ED14): the name (prefilled with the selected namespace and the separator), the type, its first
/// value(s) as text (UTF-8) and an optional TTL. A taken name says "Key already exists" and creates nothing; a created
/// key is selected in the list and opens in the editor.
struct NewKeySheet: View {
    @ObservedObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = KeyType.string
    @State private var text = ""
    @State private var rows: [Row] = [Row()]
    @State private var automaticID = true
    @State private var entryID = ""
    @State private var expires = false
    @State private var amount = ""
    @State private var unit = SetTTLSheet.DurationUnit.hours
    @State private var busy = false
    @State private var failure: String?

    /// One input row: field/value (hash, stream), member/score (sorted set), or the item alone (list, set).
    private struct Row: Identifiable {
        let id = UUID()
        var first = ""
        var second = ""
    }

    var body: some View {
        let problem = self.problem
        VStack(alignment: .leading, spacing: 14) {
            Text("New Key").font(Tokens.interface(15, weight: .semibold))
            TextField("Key name", text: $name).font(Tokens.mono(12.5)).accessibilityLabel("Key name")
            Picker("Type", selection: $type) {
                // SCAN's own names: string, hash, list, set, zset, stream.
                ForEach(NewKey.types, id: \.self) { Text(String(describing: $0)).tag($0) }
            }
            .pickerStyle(.segmented).font(Tokens.interface(12.5)).accessibilityLabel("Key type")
            values
            ttl
            if let failure {
                Text(failure).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true)
            } else if let problem, !name.isEmpty {
                Text(problem).font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction).disabled(problem != nil || busy || !browser.canCreateKey)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 520)
        // Any edit makes the last failure stale.
        .onChange(of: name) { failure = nil }
        .onChange(of: type) { failure = nil }
        .task {
            let prefill = await browser.newKeyPrefill()
            // A namespace that isn't valid UTF-8 starts empty rather than escaped, so the escape text is never taken for its bytes.
            let text = String(decoding: prefill, as: UTF8.self)
            if name.isEmpty, Data(text.utf8) == prefill { name = text }
        }
    }

    @ViewBuilder private var values: some View {
        switch type {
        case .string:
            TextEditor(text: $text).font(Tokens.mono(12.5)).frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.hair)).accessibilityLabel("Value")
        case .stream:
            Picker("ID", selection: $automaticID) {
                Text("Automatic (*)").tag(true)
                Text("Explicit").tag(false)
            }
            .pickerStyle(.segmented).font(Tokens.interface(12.5))
            if !automaticID { TextField("ID, e.g. 1700000000000-0", text: $entryID).font(Tokens.mono(12.5)).accessibilityLabel("Entry ID") }
            rowFields
        default: rowFields
        }
    }

    private var rowFields: some View {
        let labels = rowLabels
        return VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField(labels.first, text: $row.first).font(Tokens.mono(12.5)).accessibilityLabel(labels.first)
                    if let second = labels.second { TextField(second, text: $row.second).font(Tokens.mono(12.5)).accessibilityLabel(second) }
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Tokens.muted)
                    }
                    .buttonStyle(.plain).disabled(rows.count == 1).accessibilityLabel("Remove \(labels.first.lowercased())")
                }
            }
            Button("+ Add \(labels.first.lowercased())") { rows.append(Row()) }
                .buttonStyle(.plain).foregroundStyle(Tokens.accent).font(Tokens.interface(12.5))
        }
    }

    private var rowLabels: (first: String, second: String?) {
        switch type {
        case .hash, .stream: return ("Field", "Value")
        case .zset: return ("Member", "Score")
        case .list: return ("Item", nil)
        default: return ("Member", nil)
        }
    }

    private var ttl: some View {
        HStack(spacing: 8) {
            Toggle("Expire after", isOn: $expires).toggleStyle(.checkbox).font(Tokens.interface(12.5))
            TextField("Amount", text: $amount).frame(width: 80).disabled(!expires).accessibilityLabel("TTL amount")
            Picker("Unit", selection: $unit) {
                ForEach(SetTTLSheet.DurationUnit.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize().disabled(!expires).accessibilityLabel("TTL unit")
            Spacer(minLength: 0)
        }
    }

    // MARK: - Input

    private var key: Data { Data(name.utf8) }

    /// Nil only for a sorted set score that doesn't parse (`problem` says so).
    private var value: NewKey.Value? {
        func pairs() -> [DataOperation.FieldValue] { rows.map { DataOperation.FieldValue(field: Data($0.first.utf8), value: Data($0.second.utf8)) } }
        switch type {
        case .hash: return .hash(pairs())
        case .list: return .list(rows.map { Data($0.first.utf8) })
        case .set: return .set(rows.map { Data($0.first.utf8) })
        case .zset:
            var members: [DataOperation.ScoredMember] = []
            for row in rows {
                guard let score = SortedSetEditor.parseScore(row.second) else { return nil }
                members.append(DataOperation.ScoredMember(score: score, member: Data(row.first.utf8)))
            }
            return .sortedSet(members)
        case .stream: return .stream(id: automaticID ? StreamEditor.autoID : Data(entryID.trimmingCharacters(in: .whitespaces).utf8), fields: pairs())
        default: return .string(Data(text.utf8))
        }
    }

    /// The TTL in milliseconds: nil without one, `.failure` for an amount that isn't a whole number above zero.
    private var ttlMilliseconds: Result<Int64?, TTLInputError> {
        guard expires else { return .success(nil) }
        guard let count = Int64(amount.trimmingCharacters(in: .whitespaces)), count > 0 else { return .failure(TTLInputError()) }
        let (milliseconds, overflow) = count.multipliedReportingOverflow(by: unit.milliseconds)
        return overflow ? .failure(TTLInputError()) : .success(milliseconds)
    }

    private struct TTLInputError: Error {}

    private var problem: String? {
        guard let value else { return "A score is a number, inf or -inf." }
        guard case .success(let ttl) = ttlMilliseconds else { return "Enter the TTL as a whole number above zero." }
        return NewKey.problem(key: key, value: value, ttlMilliseconds: ttl)
    }

    private func create() async {
        guard let value, case .success(let ttl) = ttlMilliseconds else { return }
        busy = true; failure = nil
        defer { busy = false }
        failure = await browser.createKey(key, value, ttlMilliseconds: ttl)
        if failure == nil { dismiss() }
    }
}
