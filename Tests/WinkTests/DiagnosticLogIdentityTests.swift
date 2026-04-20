import Foundation
import Testing
@testable import Wink

@Suite("DiagnosticLog identity")
struct DiagnosticLogIdentityTests {
    @Test
    func usesWinkSubsystemAndLogPath() {
        #expect(DiagnosticLog.subsystem == "com.wink.app")
        #expect(DiagnosticLog.logFileURL().path.hasSuffix("/.config/Wink/debug.log"))
    }
}
