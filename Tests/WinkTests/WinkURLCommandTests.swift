import Foundation
import Testing
@testable import Wink

@Test func parsesToggleWithBundle() {
    let url = URL(string: "wink://toggle?bundle=com.google.Chrome")!
    #expect(WinkURLCommand.parse(url) == .toggle(bundleIdentifier: "com.google.Chrome"))
}

@Test func parsesPauseAndResumeCaseInsensitively() {
    #expect(WinkURLCommand.parse(URL(string: "wink://pause")!) == .pause)
    #expect(WinkURLCommand.parse(URL(string: "WINK://Resume")!) == .resume)
}

@Test func rejectsMalformedCommands() {
    let rejected = [
        "wink://toggle",                       // missing bundle
        "wink://toggle?bundle=",               // empty bundle
        "wink://toggle?bundle=%20%20",         // whitespace bundle
        "wink://focus?bundle=com.apple.Mail",  // unknown host
        "wink://pause/extra",                  // extra path segment
        "https://toggle?bundle=com.apple.Mail" // wrong scheme
    ]
    for raw in rejected {
        let url = URL(string: raw)!
        #expect(WinkURLCommand.parse(url) == nil, "expected rejection for \(raw)")
    }
}
