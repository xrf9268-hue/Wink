#if WINK_CARBON_HANDLER_FAULT_INJECTION
import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("Carbon handler fault injection")
struct CarbonHandlerFaultInjectionTests {
    @Test
    func configurationRequiresOneExactValidationArgument() {
        #expect(CarbonHandlerFaultInjectionConfiguration(arguments: ["Wink"]) == nil)
        #expect(CarbonHandlerFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-handler-fault=unknown",
        ]) == nil)
        #expect(CarbonHandlerFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-handler-fault=fail-once",
            "--validation-carbon-handler-fault=fail-once",
        ]) == nil)

        let configuration = CarbonHandlerFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-handler-fault=fail-once",
        ])
        #expect(configuration?.mode == .failOnce)
    }

    @Test @MainActor
    func driverFailsOnlyTheFirstHandlerInstallThenDelegatesToTheLiveFactory() throws {
        let base = RecordingFaultInjectionHandlerFactory()
        var diagnostics: [String] = []
        let configuration = try #require(CarbonHandlerFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-handler-fault=fail-once",
        ]))
        let driver = CarbonHandlerFaultInjectionDriver(
            configuration: configuration,
            baseFactory: base.factory,
            diagnosticLog: { diagnostics.append($0) }
        )

        let firstResult = driver.factory.install { _, _ in }
        guard case .failed(let firstStatus) = firstResult else {
            Issue.record("Expected the first install to be injected as failed")
            return
        }
        #expect(firstStatus == Int32(eventInternalErr))
        #expect(base.installCount == 0)

        let secondResult = driver.factory.install { _, _ in }
        guard case .installed(let session) = secondResult else {
            Issue.record("Expected the second install to delegate and succeed")
            return
        }
        #expect(session.isLive)
        #expect(base.installCount == 1)
        #expect(diagnostics.contains {
            $0.contains("CARBON_HANDLER_FAULT_INJECTION")
                && $0.contains("event=handler_install_failed")
                && $0.contains("attempt=1")
        })
        #expect(diagnostics.contains {
            $0.contains("CARBON_HANDLER_FAULT_INJECTION")
                && $0.contains("event=handler_install_forwarded")
                && $0.contains("attempt=2")
                && $0.contains("result=installed")
        })
    }
}

@MainActor
private final class RecordingFaultInjectionHandlerFactory {
    private(set) var installCount = 0

    lazy var factory = CarbonHotKeyHandlerFactory { [unowned self] _ in
        installCount += 1
        return .installed(RecordingFaultInjectionHandlerSession())
    }
}

@MainActor
private final class RecordingFaultInjectionHandlerSession: CarbonHotKeyHandlerSession {
    private(set) var isLive = true

    func stop() {
        isLive = false
    }
}
#endif
