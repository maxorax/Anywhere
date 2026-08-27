import Foundation

/// Locates the bundled routing-rules database.
///
/// `RoutingRulesDatabase` opens this file read-only and queries two tables:
/// `rules(source TEXT, type INTEGER, value TEXT)` and
/// `metadata(key TEXT, value TEXT)`. It tolerates a nil URL, so a missing or
/// empty database degrades to "no built-in rule sets" rather than a crash.
public enum TurnRules {
    public static var databaseURL: URL? {
        Bundle.module.url(forResource: "Rules", withExtension: "db")
    }
}
