import Foundation
import XCTest

@testable import KeelCore

/// NFR-PF01 evidence hook: `KEEL_LAUNCH_METRICS` makes the first sidebar render write the time since process start.
final class LaunchMetricsTests: XCTestCase {
    func testProcessStartIsInThePast() throws {
        let started = try XCTUnwrap(LaunchMetrics.processStart())
        XCTAssertLessThan(started, Date())
        XCTAssertGreaterThan(started, Date(timeIntervalSinceNow: -86_400), "this test process started today")
    }

    /// Without the variable (or with a relative path) nothing is written; with it, one report that later renders keep.
    func testWritesOnceOnlyWhenAsked() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keel-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("launch.json")

        LaunchMetrics.firstSidebarRender(environment: [:])
        LaunchMetrics.firstSidebarRender(environment: [LaunchMetrics.environmentKey: "launch.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        LaunchMetrics.firstSidebarRender(environment: [LaunchMetrics.environmentKey: file.path])
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Double])
        let seconds = try XCTUnwrap(report["first_sidebar_render_seconds"])
        XCTAssertGreaterThan(seconds, 0)

        // A second window's sidebar doesn't overwrite the first render.
        LaunchMetrics.firstSidebarRender(environment: [LaunchMetrics.environmentKey: file.path], now: Date(timeIntervalSinceNow: 3_600))
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Double])
        XCTAssertEqual(again["first_sidebar_render_seconds"], seconds)
    }
}
