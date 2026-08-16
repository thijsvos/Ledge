// Phase-0 scaffold marker (§9): the one symbol proving the LedgeCore package
// builds, links, and is importable from both the app target and `swift test`.
// Deliberately trivial and deliberately kept — a package with no public
// surface at all is a harder thing to diagnose when the build graph breaks.

/// LedgeCore's own version, independent of the app bundle's. Nothing reads it
/// in production; `ScaffoldTests` pins it, which is the whole point, so wiring
/// it to the bundle version would break that test and buy nothing.
public enum LedgeCoreInfo {
    public static let version = "0.1.0"
}
