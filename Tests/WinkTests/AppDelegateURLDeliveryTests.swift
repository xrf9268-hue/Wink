import AppKit
import Testing
@testable import Wink

@Suite("Raw wink URL Apple Event delivery")
struct AppDelegateURLDeliveryTests {
    @Test @MainActor
    func scalarDirectObjectPreservesUnicodeAuthoritySpelling() {
        let rawValue = "wink://ＰＡＵＳＥ"
        let event = makeGetURLEvent(
            directObject: NSAppleEventDescriptor(string: rawValue)
        )

        #expect(AppDelegate.rawURLStrings(from: event) == [rawValue])
        #expect(
            WinkURLCommand.parseResult(AppDelegate.rawURLStrings(from: event)[0])
                == .failure(.nonASCIIAuthority)
        )
    }

    @Test @MainActor
    func listDirectObjectPreservesOneDeliveryBatch() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "wink://search"), at: 1)
        list.insert(NSAppleEventDescriptor(string: "wink://open-settings"), at: 2)

        let event = makeGetURLEvent(directObject: list)

        #expect(AppDelegate.rawURLStrings(from: event) == [
            "wink://search",
            "wink://open-settings",
        ])
    }

    private func makeGetURLEvent(
        directObject: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            directObject,
            forKeyword: AEKeyword(keyDirectObject)
        )
        return event
    }
}
