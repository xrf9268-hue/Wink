import SwiftUI
import Testing
@testable import Wink

@Suite("Menu bar scene")
struct MenuBarSceneTests {
    @Test
    func descriptorUsesWindowStyleAndExpectedIdentity() {
        let descriptor = WinkMenuBarScene<EmptyView>.descriptor(isInserted: true)

        #expect(descriptor.title == "Wink")
        #expect(descriptor.imageName == "MenuBarTemplate")
        #expect(descriptor.usesWindowStyle == true)
        #expect(descriptor.usesCustomTemplateLabel == true)
    }

    @Test
    func descriptorReflectsInsertedBindingState() {
        #expect(WinkMenuBarScene<EmptyView>.descriptor(isInserted: true).isInserted == true)
        #expect(WinkMenuBarScene<EmptyView>.descriptor(isInserted: false).isInserted == false)
    }

    @Test
    func resourceBundleResolvesToANonNilBundle() {
        let bundlePath = WinkResourceBundle.bundle.bundlePath
        #expect(!bundlePath.isEmpty)
    }
}
