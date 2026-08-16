@testable import LedgeCore
import XCTest

/// ULID minting (§2.3). These exist because human QA found the agent inventing
/// ULID-shaped words — `01KZQBARTENDER0ICONISSUE18`, a 28-character
/// `01KZQPOSTMVPPLANNINGTHOUGHT0` — so every property that made those wrong is
/// pinned here.
final class ULIDTests: XCTestCase {
    /// Deterministic generator so a whole ID can be asserted, not just its shape.
    private struct FixedGenerator: RandomNumberGenerator {
        var value: UInt64 = 0
        mutating func next() -> UInt64 {
            value
        }
    }

    private let now = utcDate("2026-08-16T20:16:00Z")

    // MARK: - Shape

    func testIsExactlyTwentySixCharacters() {
        XCTAssertEqual(ULID.make(at: now).count, 26)
    }

    /// The failures QA found were 25 and 28 characters. Length must not drift
    /// with the clock.
    func testLengthIsStableAcrossTheDateRange() {
        for iso in [
            "1970-01-01T00:00:00Z",
            "2026-08-16T20:16:00Z",
            "2099-12-31T23:59:59Z",
        ] {
            XCTAssertEqual(ULID.make(at: utcDate(iso)).count, 26, iso)
        }
    }

    /// Crockford base32 omits I, L, O and U. Every invented ID QA found used at
    /// least one of them.
    func testUsesOnlyCrockfordBase32() {
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for _ in 0 ..< 200 {
            let id = ULID.make(at: now)
            XCTAssertTrue(id.allSatisfy(allowed.contains), id)
        }
    }

    func testRejectsTheAmbiguousLettersSpecifically() {
        for _ in 0 ..< 200 {
            let id = ULID.make(at: now)
            for character in "ILOU" {
                XCTAssertFalse(id.contains(character), "\(id) contains \(character)")
            }
        }
    }

    // MARK: - The timestamp prefix (the whole reason for a ULID)

    func testFirstTenCharactersEncodeTheTime() {
        var generator = FixedGenerator()
        let id = ULID.make(at: now, using: &generator)
        XCTAssertEqual(String(id.prefix(10)), String(ULID.timeCharacters(for: now)))
    }

    /// IDs must sort chronologically as plain strings — that is what makes a
    /// directory listing a timeline. The invented ones sorted as noise.
    func testLaterTimestampsSortAfterEarlierOnes() {
        var generator = FixedGenerator()
        let ids = [
            "2026-08-16T20:16:00Z",
            "2026-08-16T20:16:01Z",
            "2026-08-17T00:00:00Z",
            "2027-01-01T00:00:00Z",
        ].map { ULID.make(at: utcDate($0), using: &generator) }

        XCTAssertEqual(ids, ids.sorted(), "ULIDs must sort chronologically as strings")
    }

    func testSameMillisecondStillYieldsDistinctIDs() {
        let ids = Set((0 ..< 50).map { _ in ULID.make(at: now) })
        XCTAssertEqual(ids.count, 50, "the random half must keep same-instant IDs apart")
    }

    /// A date before the epoch clamps rather than trapping on the unsigned
    /// conversion.
    func testPreEpochDateDoesNotTrap() {
        XCTAssertEqual(ULID.make(at: Date(timeIntervalSince1970: -10000)).count, 26)
    }

    // MARK: - Against the real thing

    /// The vault's own seeded notes look like this; the agent's did not.
    func testMatchesTheShapeOfAGenuineVaultID() {
        let genuine = "01K2Q5T8YXM6ZVN9C3H4J7RSPQ"
        let minted = ULID.make(at: now)
        XCTAssertEqual(minted.count, genuine.count)
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(genuine.allSatisfy(allowed.contains))
        XCTAssertTrue(minted.allSatisfy(allowed.contains))
    }
}
