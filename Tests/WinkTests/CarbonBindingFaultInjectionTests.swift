#if WINK_CARBON_BINDING_FAULT_INJECTION
import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("Carbon binding fault injection")
struct CarbonBindingFaultInjectionTests {
    @Test
    func configurationRequiresOneExactPermanentConflictTuple() {
        #expect(CarbonBindingFaultInjectionConfiguration(arguments: ["Wink"]) == nil)
        #expect(CarbonBindingFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-binding-fault=permanent-conflict:38",
        ]) == nil)
        #expect(CarbonBindingFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-binding-fault=unknown:38:6400",
        ]) == nil)
        #expect(CarbonBindingFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-binding-fault=permanent-conflict:38:6400",
            "--validation-carbon-binding-fault=permanent-conflict:38:6400",
        ]) == nil)

        let configuration = CarbonBindingFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-binding-fault=permanent-conflict:38:6400",
        ])
        #expect(configuration?.mode == .permanentConflict)
        #expect(configuration?.keyCode == 38)
        #expect(configuration?.modifiers == 6_400)
    }

    @Test @MainActor
    func driverInjectsOnlyTheExactBindingAndReportsCumulativeCounters() throws {
        let base = RecordingFaultInjectionRegistrationClient()
        var diagnostics: [String] = []
        let configuration = try #require(CarbonBindingFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-carbon-binding-fault=permanent-conflict:38:6400",
        ]))
        let driver = CarbonBindingFaultInjectionDriver(
            configuration: configuration,
            baseClient: base.client,
            diagnosticLog: { diagnostics.append($0) }
        )
        let client = driver.client

        let firstConflict = client.register(
            38,
            6_400,
            EventHotKeyID(signature: 1, id: 1)
        )
        let secondConflict = client.register(
            38,
            6_400,
            EventHotKeyID(signature: 1, id: 2)
        )
        #expect(firstConflict.status == Int32(eventHotKeyExistsErr))
        #expect(firstConflict.hotKeyRef == nil)
        #expect(secondConflict.status == Int32(eventHotKeyExistsErr))
        #expect(secondConflict.hotKeyRef == nil)
        #expect(base.registrations.isEmpty)

        let forwarded = client.register(
            40,
            6_400,
            EventHotKeyID(signature: 1, id: 3)
        )
        let forwardedRef = try #require(forwarded.hotKeyRef)
        #expect(forwarded.status == noErr)
        #expect(base.registrations.count == 1)
        #expect(base.registrations.first?.keyCode == 40)

        let sameKeyDifferentModifiers = client.register(
            38,
            6_912,
            EventHotKeyID(signature: 1, id: 4)
        )
        let sameKeyDifferentModifiersRef = try #require(
            sameKeyDifferentModifiers.hotKeyRef
        )
        #expect(sameKeyDifferentModifiers.status == noErr)
        #expect(base.registrations.count == 2)
        #expect(base.registrations.last?.keyCode == 38)
        #expect(base.registrations.last?.modifiers == 6_912)

        client.unregister(forwardedRef)
        client.unregister(sameKeyDifferentModifiersRef)

        #expect(base.unregisteredRefs == [forwardedRef, sameKeyDifferentModifiersRef])
        #expect(diagnostics.contains {
            $0.contains("CARBON_BINDING_FAULT_INJECTION")
                && $0.contains("event=register_injected")
                && $0.contains("status=\(eventHotKeyExistsErr)")
                && $0.contains("registerCalls=2")
                && $0.contains("forwardedRegisterCalls=0")
                && $0.contains("injectedFailures=2")
                && $0.contains("unregisterCalls=0")
        })
        #expect(diagnostics.contains {
            $0.contains("CARBON_BINDING_FAULT_INJECTION")
                && $0.contains("event=unregister_forwarded")
                && $0.contains("registerCalls=4")
                && $0.contains("forwardedRegisterCalls=2")
                && $0.contains("injectedFailures=2")
                && $0.contains("unregisterCalls=2")
        })
    }
}

@MainActor
private final class RecordingFaultInjectionRegistrationClient {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let identifier: UInt32
    }

    private(set) var registrations: [Registration] = []
    private(set) var unregisteredRefs: [EventHotKeyRef] = []

    lazy var client = CarbonHotKeyRegistrationClient(
        register: { [unowned self] keyCode, modifiers, hotKeyID in
            registrations.append(Registration(
                keyCode: keyCode,
                modifiers: modifiers,
                identifier: hotKeyID.id
            ))
            return (noErr, OpaquePointer(bitPattern: Int(hotKeyID.id)))
        },
        unregister: { [unowned self] hotKeyRef in
            unregisteredRefs.append(hotKeyRef)
        }
    )
}
#endif
