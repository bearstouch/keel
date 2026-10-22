import Foundation
import XCTest
@testable import KeelRESP

/// SplitMix64: a tiny seeded generator, so a failing case can be replayed from its seed and index.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class RESPFuzzTests: XCTestCase {
    /// AC4 asks for at least 1,000,000 cases; `KEEL_FUZZ_ITERATIONS` raises it for longer local runs.
    private let iterations = ProcessInfo.processInfo.environment["KEEL_FUZZ_ITERATIONS"].flatMap(Int.init).map { max($0, 1_000_000) } ?? 1_000_000
    private let seed: UInt64 = 0x4B45_454C_2D30_3034  // "KEEL-004"
    /// Generous: a hang shows up as a timeout, not as a slow pass. Debug builds on CI take well under this.
    private let timeBudget: TimeInterval = 600

    /// Tiny limits so the fuzzer also reaches the depth, element and reply-size failure paths.
    private let tight = RESPLimits(maxReplyBytes: 48, maxDepth: 3, maxElements: 6)
    private let alphabet = Array("+-:$*_,#(!=%~>|?\r\n0123456789.eEtfinax ".utf8)

    func testRandomInputsNeverCrash() throws {
        var rng = SeededGenerator(state: seed)
        let fixtures = RESPFixtures.all.map(\.frame)
        let start = Date()
        var decoded = 0, failed = 0
        for index in 0..<iterations {
            let input: [UInt8]
            switch rng.next() % 4 {
            case 0, 1: input = mutate(fixtures.randomElement(using: &rng)!, using: &rng)
            case 2: input = (0..<Int.random(in: 0...48, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            default: input = (0..<Int.random(in: 0...48, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            }
            let limits = index.isMultiple(of: 2) ? RESPLimits.standard : tight
            do {
                for value in try parse(input, limits: limits, using: &rng) {
                    decoded += 1
                    // Anything the parser accepts must survive its own encoder.
                    let encoded = Array(try RESPEncoder.encode(value))
                    XCTAssertEqual(try RESPFixtures.parse(encoded, limits: limits), [value], "seed \(seed) case \(index)")
                }
            } catch {
                failed += 1
            }
            if index.isMultiple(of: 65_536) { XCTAssertLessThan(Date().timeIntervalSince(start), timeBudget, "fuzzing too slow at case \(index)") }
        }
        // Both outcomes must be common, or the generator has drifted into testing only one path.
        XCTAssertGreaterThan(decoded, iterations / 50)
        XCTAssertGreaterThan(failed, iterations / 50)
    }

    /// Feeds `input` in one to three random chunks and drains it. A parse that neither returns a value, waits
    /// nor throws within a bounded number of calls is a hang.
    private func parse(_ input: [UInt8], limits: RESPLimits, using rng: inout SeededGenerator) throws -> [RESPValue] {
        var cuts = (0..<Int.random(in: 0...2, using: &rng)).map { _ in Int.random(in: 0...input.count, using: &rng) }.sorted()
        cuts.append(input.count)
        var parser = RESPParser(limits: limits)
        var values: [RESPValue] = []
        var from = 0
        for cut in cuts {
            parser.append(input[from..<cut]); from = cut
            while let value = try parser.next() {
                values.append(value)
                guard values.count <= input.count else { XCTFail("more replies than bytes"); return values }
            }
        }
        return values
    }

    private func mutate(_ frame: [UInt8], using rng: inout SeededGenerator) -> [UInt8] {
        var bytes = frame
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            let at = Int.random(in: 0...bytes.count, using: &rng)
            switch rng.next() % 7 {
            case 0 where at < bytes.count: bytes[at] ^= 1 << UInt8.random(in: 0...7, using: &rng)
            case 1 where at < bytes.count: bytes[at] = alphabet.randomElement(using: &rng)!
            case 2: bytes.insert(alphabet.randomElement(using: &rng)!, at: at)
            case 3 where at < bytes.count: bytes.remove(at: at)
            case 4: bytes = Array(bytes[..<at])
            case 5: bytes += bytes[at...]
            default: bytes.insert(contentsOf: Array(String(Int.random(in: -2...100_000_000, using: &rng)).utf8), at: at)
            }
        }
        return bytes
    }
}
