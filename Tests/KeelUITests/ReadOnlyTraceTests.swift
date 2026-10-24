import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// KEEL-037 AC3 (FR-SF01): with read-only on, every editor action sends nothing that writes. The trace is every
/// command the in-memory server received; each must be a read. The data path is driven directly too, past the
/// editors' own guards, so the policy is what refuses.
final class ReadOnlyTraceTests: XCTestCase {
    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// Fails for any traced command that isn't a read or harmless (`WATCH`, `MULTI`, `EXEC` and writes all fail).
    private func assertOnlyReads(_ server: TransactionalKeyspace, file: StaticString = #filePath, line: UInt = #line) {
        for command in server.commands {
            let arguments = command.map { Data($0.utf8) }
            let safetyClass = SafetyPolicy.classify(arguments, command: CommandCatalog.bundled.resolve(arguments))
            XCTAssertFalse(safetyClass.mayWrite, "\(command[0]) was sent on a read-only profile", file: file, line: line)
        }
    }

    /// Every write an editor, key action or the new-key sheet can ask for.
    private var writes: [DataOperation] {
        let key = d("k")
        return [
            .stringSet(key: key, value: d("v"), keepTTL: true), .stringCreate(key: key, value: d("v"), milliseconds: 1_000),
            .hashSetField(key: key, field: d("f"), value: d("v")), .hashDeleteFields(key: key, fields: [d("f")]),
            .listPush(key: key, values: [d("v")], atHead: true), .listSet(key: key, index: 0, value: d("v")), .listRemove(key: key, count: 1, value: d("v")),
            .listPop(key: key, atHead: false), .listInsert(key: key, before: true, pivot: d("p"), value: d("v")),
            .setAdd(key: key, members: [d("m")]), .setRemove(key: key, members: [d("m")]),
            .sortedSetAdd(key: key, members: [.init(score: 1, member: d("m"))], existingOnly: true), .sortedSetIncrement(key: key, increment: 1, member: d("m")),
            .sortedSetRemove(key: key, members: [d("m")]), .streamAdd(key: key, id: d("*"), fields: [.init(field: d("f"), value: d("v"))]),
            .streamDelete(key: key, ids: [d("1-0")]), .rename(key: key, newKey: d("k2"), overwrite: false), .rename(key: key, newKey: d("k2"), overwrite: true),
            .expire(key: key, milliseconds: 1_000), .expireAt(key: key, unixMilliseconds: 4_000_000_000_000), .persist(key: key), .delete(keys: [key]),
            .delete(keys: [key, d("k2")]), .flushDatabase(async: true), .flushAll(async: false)
        ]
    }

    /// The common shell actions: edit the viewer, save, overwrite, run an immediate write, rename, TTL, delete.
    @MainActor private func runShellActions(_ editor: EditorSession) async {
        editor.viewer.edit("changed")
        await editor.save()
        await editor.overwrite()
        await editor.run([.stringSet(key: editor.key, value: d("x"), keepTTL: true)], watch: nil)
        _ = await editor.rename(to: d("renamed"))
        _ = await editor.setTTL(.after(milliseconds: 60_000))
        _ = await editor.setTTL(.persist)
        _ = await editor.delete()
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    @MainActor func testEveryEditorActionSendsNothingOnReadOnly() async {
        let string = TransactionalKeyspace(["s": "value"])
        let stringEditor = string.session("s", type: .string, readOnly: true, production: true)
        await stringEditor.load()
        await runShellActions(stringEditor)
        assertOnlyReads(string)

        let hash = TransactionalKeyspace(hashes: ["h": [("a", "1")]])
        let hashEditor = hash.session("h", type: .hash, readOnly: true, production: true)
        let hashModel = HashEditorModel(session: hashEditor)
        await hashEditor.load()
        await hashModel.add(field: d("b"), value: d("2"))
        await hashModel.rename(d("a"), to: d("z"))
        hashModel.confirmOverwrite()
        hashModel.delete(d("a"))
        await runShellActions(hashEditor)
        assertOnlyReads(hash)

        let list = TransactionalKeyspace(lists: ["q": ["a", "b", "c"]])
        let listEditor = list.session("q", type: .list, readOnly: true, production: true)
        let listModel = ListEditorModel(session: listEditor)
        await listEditor.load()
        listModel.delete(d("1"))
        await listModel.push(d("n"), atHead: true)
        await listModel.pop(atHead: false)
        await listModel.confirmPop()
        await listModel.insert(d("n"), relativeTo: d("0"), before: true)
        await runShellActions(listEditor)
        assertOnlyReads(list)

        let set = TransactionalKeyspace(sets: ["s": ["red", "green"]])
        let setEditor = set.session("s", type: .set, readOnly: true, production: true)
        let setModel = SetEditorModel(session: setEditor)
        await setEditor.load()
        await setModel.add(d("blue"))
        setModel.remove(d("red"))
        await runShellActions(setEditor)
        assertOnlyReads(set)

        let zset = TransactionalKeyspace(zsets: ["z": [("a", 1), ("b", 2)]])
        let zsetEditor = zset.session("z", type: .zset, readOnly: true, production: true)
        let zsetModel = SortedSetEditorModel(session: zsetEditor)
        await zsetEditor.load()
        _ = zsetModel.changeScore(d("a"), to: "5")
        zsetModel.remove(d("b"))
        await zsetModel.add(d("c"), score: "3")
        await zsetModel.increment(d("a"), by: "1")
        await runShellActions(zsetEditor)
        assertOnlyReads(zset)

        let stream = TransactionalKeyspace(streams: ["x": [("1700000000000-0", [("f", "v")])]])
        let streamEditor = stream.session("x", type: .stream, readOnly: true, production: true)
        let streamModel = StreamEditorModel(session: streamEditor)
        await streamEditor.load()
        let added = await streamModel.add(id: d("*"), fields: [.init(field: d("f"), value: d("v"))])
        XCTAssertFalse(added)
        await runShellActions(streamEditor)
        assertOnlyReads(stream)
    }

    /// Past the editors' guards: every write, single or in a save, is refused by the data path with `READ_ONLY`.
    @MainActor func testDataPathRefusesEveryWriteOnReadOnly() async {
        let server = TransactionalKeyspace(["k": "v"])
        let editor = server.session("k", readOnly: true, production: true)
        let confirmed = DataContext(profile: editor.context.profile, confirmation: CommandConfirmation(scope: .keys([d("k"), d("k2")]), database: 0))
        for write in writes {
            for context in [editor.context, confirmed] {
                do {
                    _ = try await editor.service.execute(.operation(write), origin: .editor, context: context)
                    XCTFail("\(write) ran")
                } catch { XCTAssertEqual(error.code, "READ_ONLY", "\(write)") }
                do {
                    _ = try await editor.service.executeTransaction([write], unchanged: nil, context: context)
                    XCTFail("\(write) saved")
                } catch { XCTAssertEqual(error.code, "READ_ONLY", "\(write)") }
            }
        }
        XCTAssertEqual(server.commands, [], "nothing at all reached the server")
    }
}
