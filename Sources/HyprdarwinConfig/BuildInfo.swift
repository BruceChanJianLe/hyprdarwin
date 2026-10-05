import Foundation

/// Which hyprdarwin this is. The semver comes from the repository's VERSION
/// file; scripts/build-app.sh stamps it into Info.plist with the build number
/// and the git commit, and everything else (menu, About panel, log,
/// `--version`, Lua's `hd.version`) reads it from there.
public struct BuildInfo: Equatable, Sendable, CustomStringConvertible {
    /// Semver, e.g. "0.2.0"; "dev" outside an app bundle (`swift run`, tests).
    public var version: String
    /// Short git commit, "-dirty" when built from uncommitted changes.
    public var commit: String?
    /// CFBundleVersion: the CI run number, or the commit count locally.
    public var build: String?
    /// "run" for a GitHub Actions build, "local" otherwise.
    public var origin: String?

    public init(version: String, commit: String? = nil, build: String? = nil, origin: String? = nil) {
        self.version = version
        self.commit = commit
        self.build = build
        self.origin = origin
    }

    public init(infoDictionary info: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let text = info?[key] as? String, !text.isEmpty, !text.hasPrefix("__") else { return nil }
            return text
        }
        self.init(version: value("CFBundleShortVersionString") ?? "dev", commit: value("HyprdarwinCommit"),
                  build: value("CFBundleVersion"), origin: value("HyprdarwinBuildOrigin"))
    }

    /// The running app's.
    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

    /// "0.2.0 (abc1234, run 57)", "0.2.0 (abc1234, local build 120)" or "dev".
    public var description: String {
        var details: [String] = []
        if let commit { details.append(commit) }
        if let build { details.append(origin == "run" ? "run \(build)" : "local build \(build)") }
        return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
    }
}
