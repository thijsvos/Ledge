import LedgeCore
import XCTest

/// NativeCommand: identity (names/summaries/declaration order), the
/// exact-match rule deciding what a submit executes natively, the prefix
/// filter behind the suggestion list, and the `SubmitAction` precedence seam
/// — native match BEFORE the §5 router — that CaptureCoordinator.submit
/// routes through (the coordinator itself is App-layer and untestable here;
/// this pure function IS the precedence rule).
final class NativeCommandTests: XCTestCase {
    // MARK: - Identity

    func testDeclarationOrderAndNames() {
        // Declaration order is presentation order (documented choice — the
        // suggestion list shows exactly this, not alphabetical).
        XCTAssertEqual(
            NativeCommand.allCases.map(\.name),
            ["help", "settings", "checks", "vault", "resume", "cancel", "changes", "undo", "quit"]
        )
    }

    func testEveryCommandHasANonEmptySummary() {
        for command in NativeCommand.allCases {
            XCTAssertFalse(command.summary.isEmpty, command.name)
        }
    }

    // MARK: - match(input:) exact-match matrix

    func testEveryCommandMatchesItsSlashName() {
        for command in NativeCommand.allCases {
            XCTAssertEqual(NativeCommand.match(input: "/" + command.name), command)
        }
    }

    func testMatchTrimsSurroundingWhitespace() {
        // Typeahead completion submits "/cancel " (trailing space) — it MUST
        // still execute natively.
        XCTAssertEqual(NativeCommand.match(input: "/cancel "), .cancel)
        XCTAssertEqual(NativeCommand.match(input: "  /cancel"), .cancel)
        XCTAssertEqual(NativeCommand.match(input: "\n/quit\n"), .quit)
    }

    func testNearMissesNeverMatch() {
        for input in [
            "/Cancel", // case-sensitive
            "/CANCEL",
            "/cancelx", // not the whole name
            "cancel", // no slash
            "/cancel now", // arguments → agent prompt, not native
            "/ cancel", // space after the slash
            "/",
            "",
            "/helpp",
            "/set", // a prefix of a name is not the name
            "//help",
        ] {
            XCTAssertNil(NativeCommand.match(input: input), input)
        }
    }

    // MARK: - matching(prefix:) (the suggestion list's source)

    func testEmptyPrefixMatchesEverythingInDeclarationOrder() {
        XCTAssertEqual(NativeCommand.matching(prefix: ""), NativeCommand.allCases)
    }

    func testPrefixFilterIsCaseInsensitiveAndOrderPreserving() {
        XCTAssertEqual(NativeCommand.matching(prefix: "c"), [.checks, .cancel, .changes])
        XCTAssertEqual(NativeCommand.matching(prefix: "C"), [.checks, .cancel, .changes])
        XCTAssertEqual(NativeCommand.matching(prefix: "ca"), [.cancel])
        // "ch" stopped being unique to /checks when /changes joined the list —
        // the shadowing this enum's doc comment warns about, made explicit.
        XCTAssertEqual(NativeCommand.matching(prefix: "ch"), [.checks, .changes])
        XCTAssertEqual(NativeCommand.matching(prefix: "che"), [.checks])
        XCTAssertEqual(NativeCommand.matching(prefix: "cha"), [.changes])
        XCTAssertEqual(NativeCommand.matching(prefix: "quit"), [.quit])
        XCTAssertEqual(NativeCommand.matching(prefix: "z"), [])
        XCTAssertEqual(NativeCommand.matching(prefix: "help "), [])
    }

    // MARK: - SubmitAction precedence (native BEFORE the router)

    func testNativeMatchWinsBeforeTheRouter() {
        XCTAssertEqual(SubmitAction.decide("/cancel"), .native(.cancel))
        // The §5 router would read these as agent "cancel " / daily text —
        // the native check runs first, on the trimmed input.
        XCTAssertEqual(SubmitAction.decide("/cancel "), .native(.cancel))
        XCTAssertEqual(SubmitAction.decide(" /cancel"), .native(.cancel))
        for command in NativeCommand.allCases {
            XCTAssertEqual(SubmitAction.decide("/" + command.name), .native(command))
        }
    }

    func testNonNativeInputsRouteExactlyPerSection5() {
        XCTAssertEqual(
            SubmitAction.decide("/cancel now"),
            .routed(.agent(prompt: "cancel now"))
        )
        XCTAssertEqual(
            SubmitAction.decide("/vet the diff"),
            .routed(.agent(prompt: "vet the diff"))
        )
        XCTAssertEqual(SubmitAction.decide("/"), .routed(.agent(prompt: "")))
        XCTAssertEqual(
            SubmitAction.decide("hello"),
            .routed(.instant(target: .daily, text: "hello"))
        )
        XCTAssertEqual(
            SubmitAction.decide(".i note"),
            .routed(.instant(target: .inbox, text: "note"))
        )
        XCTAssertEqual(
            SubmitAction.decide(""),
            .routed(.instant(target: .daily, text: ""))
        )
    }
}
