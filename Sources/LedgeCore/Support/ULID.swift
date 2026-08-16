// ULID minting for notes Ledge creates on the agent's behalf (§2.3).
//
// register identifies every note with a ULID: 26 Crockford base32 characters,
// the first 10 encoding the creation time in milliseconds. That prefix is the
// whole point — IDs sort chronologically, so a directory listing is a timeline.
//
// An agent cannot produce one. It has no clock and no entropy, so asked for an
// `id:` it writes something ULID-SHAPED instead: human QA came back with
// `01KZQBARTENDER0ICONISSUE18`, `01KZQPOSTMVPPLANNINGTHOUGHT0` (28 characters),
// and `01KZQMEDIA0TEST0000000017` (25) — words spelled in an alphabet that
// excludes I, L, O and U precisely to avoid ambiguity, sorting as noise.
//
// So Ledge mints it. The contract asks the agent for a placeholder and
// PlanContract.fillingIdentifiers swaps in the real thing before the plan is
// ever validated, which keeps the byte counts and pre-images honest.

import Foundation

public enum ULID {
    /// Crockford base32 — I, L, O and U are absent by design, so an ID can be
    /// read aloud or transcribed without ambiguity.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(at date: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(at: date, using: &generator)
    }

    /// The generator is injectable so tests can pin the random half and assert
    /// on a whole ID rather than only on its shape.
    public static func make(at date: Date, using generator: inout some RandomNumberGenerator) -> String {
        var characters = timeCharacters(for: date)
        for _ in 0 ..< 16 {
            characters.append(alphabet[Int.random(in: 0 ..< 32, using: &generator)])
        }
        return String(characters)
    }

    /// The 48-bit millisecond timestamp as 10 characters (50 bits, top two
    /// always zero). Dates before the epoch clamp to it rather than trapping on
    /// the unsigned conversion — a vault is not a time machine.
    static func timeCharacters(for date: Date) -> [Character] {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        return (0 ..< 10).map { index in
            alphabet[Int((milliseconds >> (45 - 5 * index)) & 0x1F)]
        }
    }
}
