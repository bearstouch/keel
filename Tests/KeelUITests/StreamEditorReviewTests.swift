import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Review findings for the stream viewer (KEEL-034).
final class StreamEditorReviewTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// An explicit ID that isn't one (`MAXLEN`, `MINID`, `NOMKSTREAM`) would be read by `XADD` as an option: `XADD s
    /// MAXLEN 0 * f v` trims the stream to nothing. The sheet refuses it before anything is sent.
    @MainActor func testExplicitIDCannotBeAnXAddOption() async {
        let server = TransactionalKeyspace(streams: ["events": [("1-0", [("type", "a")])]])
        let editor = server.session("events", type: .stream)
        let model = StreamEditorModel(session: editor)
        await editor.load()
        for id in ["MAXLEN", "minid", "NOMKSTREAM", "~1-0", "-1"] {
            let added = await model.add(id: d(id), fields: [.init(field: d("0"), value: d("*")), .init(field: d("f"), value: d("v"))])
            XCTAssertFalse(added, id)
            XCTAssertEqual(model.failure, "An entry ID starts with a digit (1700000000000-0).", id)
        }
        XCTAssertFalse(server.commandNames.contains("XADD"))
        XCTAssertNil(StreamEditorModel.problem(id: d("5"), fields: [.init(field: d("f"), value: Data())]), "a bare millisecond time is an ID")
        XCTAssertNil(StreamEditorModel.problem(id: d("5-*"), fields: [.init(field: d("f"), value: Data())]))
        XCTAssertNil(StreamEditorModel.problem(id: StreamEditor.autoID, fields: [.init(field: d("f"), value: Data())]))
    }

    /// An add whose read-back fails keeps the oldest-first page on screen: the table must keep calling it oldest first
    /// (it isn't the newest page), and Load more continues in that direction.
    @MainActor func testFailedReadBackKeepsPageOrder() async {
        let entries = (0..<600).map { ("\(1_000 + $0)-0", [("n", "\($0)")]) }
        let server = TransactionalKeyspace(streams: ["events": entries])
        let gate = Gate()
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            if gate.closed { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            let connection = RedisConnection(transport: TransactionalKeyspace.Transport(server))
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "")
            }
            return connection
        }
        let editor = EditorSession(
            key: d("events"), type: .stream, binding: EditorBinding.editor(for: .stream), service: DataCommandService(session: session),
            context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
        let model = StreamEditorModel(session: editor)
        await editor.load()
        await model.toggleOrder()
        XCTAssertFalse(model.newestFirst)
        XCTAssertEqual(model.rows.first?.id, d("1000-0"))

        // The add runs, its reply is lost, and reconnecting for the read-back fails.
        server.dropNextExecReply = true
        gate.closed = true
        let added = await model.add(id: StreamEditor.autoID, fields: [.init(field: d("f"), value: d("v"))])
        XCTAssertFalse(added)
        XCTAssertNotNil(editor.actionFailure)
        XCTAssertEqual(editor.loaded?.rows.count, 500, "the oldest page is still what's loaded")
        XCTAssertFalse(model.newestFirst, "the oldest page isn't labelled newest first")
        XCTAssertEqual(model.rows.first?.id, d("1000-0"))
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var closed: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
