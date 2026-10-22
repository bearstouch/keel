import XCTest
@testable import KeelCore

final class LaunchArgumentsTests: XCTestCase {
    func testParsesStateDirectoryAndFlags() throws {
        let parsed = try LaunchArguments.parse(["--state-directory", "/tmp/keel-state/", "--no-mcp", "--fixture"])
        XCTAssertEqual(parsed.stateDirectory?.path, "/tmp/keel-state")
        XCTAssertTrue(parsed.noMCP)
        XCTAssertTrue(parsed.fixture)
        XCTAssertFalse(parsed.mcpAllowed)

        XCTAssertEqual(try LaunchArguments.parse(["--state-directory=/var/keel"]).stateDirectory?.path, "/var/keel")
        XCTAssertEqual(try LaunchArguments.parse([]), LaunchArguments())
        XCTAssertTrue(try LaunchArguments.parse([]).mcpAllowed, "A plain launch may start MCP if settings allow it")
        XCTAssertFalse(try LaunchArguments.parse(["--fixture"]).mcpAllowed, "Fixture launches never listen")

        assertParse(["--verbose"], throws: .unknownArgument("--verbose"))
        assertParse(["--no-mcp=yes"], throws: .unknownArgument("--no-mcp=yes"))
        assertParse(["stray"], throws: .unknownArgument("stray"))
        assertParse(["--state-directory"], throws: .missingValue("--state-directory"))
        assertParse(["--state-directory", "--no-mcp"], throws: .missingValue("--state-directory"), "A following flag is never taken as the path")
    }

    func testRejectsRelativeStateDirectory() {
        for path in ["state", "./state", "~/state"] { assertParse(["--state-directory", path], throws: .relativeStateDirectory(path)) }
    }

    func testIgnoresArgumentsAddedByTheSystem() throws {
        let parsed = try LaunchArguments.parse(["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", "--no-mcp"])
        XCTAssertEqual(parsed, LaunchArguments(noMCP: true))
        XCTAssertEqual(try LaunchArguments.parse(["-NSQuitAlwaysKeepsWindows", "--fixture"]), LaunchArguments(fixture: true), "A Keel flag is never taken as a default's value")
    }

    private func assertParse(
        _ arguments: [String], throws expected: LaunchArguments.ParseError, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try LaunchArguments.parse(arguments), message, file: file, line: line) {
            XCTAssertEqual($0 as? LaunchArguments.ParseError, expected, message, file: file, line: line)
        }
    }
}

final class AppIdentityTests: XCTestCase {
    func testDevBuildsUseDevBundleIdentity() {
        XCTAssertEqual(AppInstanceIdentity(bundleIdentifier: nil).identifier, "com.bearstouch.keel.dev")
        XCTAssertTrue(AppInstanceIdentity(bundleIdentifier: nil).isDevelopment)
        XCTAssertFalse(AppInstanceIdentity(bundleIdentifier: "com.bearstouch.keel").isDevelopment)
        XCTAssertTrue(AppInstanceIdentity(bundleIdentifier: "com.bearstouch.keel.dev").isDevelopment)
    }
}

final class StateLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keel-state-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testResolvesStateDirectoryFixtureAndDefault() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let dev = AppInstanceIdentity(bundleIdentifier: nil)
        let explicit = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        XCTAssertEqual(StateLocation.resolve(arguments: LaunchArguments(stateDirectory: explicit, fixture: true), identity: dev, applicationSupport: support, temporary: temporary), explicit)
        XCTAssertEqual(StateLocation.resolve(arguments: LaunchArguments(), identity: dev, applicationSupport: support, temporary: temporary).lastPathComponent, "com.bearstouch.keel.dev")
        let fixture = StateLocation.resolve(arguments: LaunchArguments(fixture: true), identity: dev, applicationSupport: support, temporary: temporary)
        XCTAssertTrue(fixture.path.hasPrefix("/tmp/keel-fixture-"), "Fixture state is isolated from the real state directory")
    }

    func testPrepareCreatesOwnerOnlyFolder() throws {
        let directory = root.appendingPathComponent("state", isDirectory: true)
        try StateLocation.prepare(directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNoThrow(try StateLocation.prepare(directory), "An existing folder is reused")
    }

    func testPrepareRefusesSymlinksAndFiles() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try StateLocation.prepare(file)) { XCTAssertEqual($0 as? StateLocation.Failure, .notADirectory(file.path)) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try StateLocation.prepare(link)) { XCTAssertEqual($0 as? StateLocation.Failure, .symlink(link.path)) }
        XCTAssertThrowsError(try StateLocation.prepare(URL(fileURLWithPath: "/usr", isDirectory: true)), "A folder owned by another account is refused") {
            XCTAssertEqual($0 as? StateLocation.Failure, .notOwned("/usr"))
        }
    }

    func testPrepareTightensExistingFolder() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try StateLocation.prepare(root)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
