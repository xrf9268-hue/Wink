import Foundation

/// Commands accepted on the `wink://` URL scheme. Parsing is pure and
/// side-effect free so the accepted grammar is fully unit-testable:
///
///     wink://toggle?bundle=<bundle-identifier>
///     wink://pause
///     wink://resume
///
/// Anything else — unknown hosts, missing/empty bundle, extra path
/// segments — parses to nil and the caller logs and ignores it. The
/// scheme is callable by any local process, which matches the threat
/// model of every macOS URL scheme: it can do nothing a Dock click or
/// the menu bar toggle cannot.
enum WinkURLCommand: Equatable {
    case toggle(bundleIdentifier: String)
    case pause
    case resume

    static func parse(_ url: URL) -> WinkURLCommand? {
        guard url.scheme?.lowercased() == "wink",
              let host = url.host?.lowercased(),
              url.path.isEmpty || url.path == "/" else {
            return nil
        }

        switch host {
        case "toggle":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let bundle = components?.queryItems?
                    .first(where: { $0.name == "bundle" })?
                    .value?
                    .trimmingCharacters(in: .whitespaces),
                  !bundle.isEmpty else {
                return nil
            }
            return .toggle(bundleIdentifier: bundle)
        case "pause":
            return .pause
        case "resume":
            return .resume
        default:
            return nil
        }
    }
}
