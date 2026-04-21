import Foundation
import Testing
@testable import Wink

@Suite("WinkRecipeCodec")
struct WinkRecipeCodecTests {
    @Test
    func encodesAndDecodesVersionOneRecipes() throws {
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command", "shift"],
                    isEnabled: true
                )
            ]
        )

        let codec = WinkRecipeCodec()
        let data = try codec.encode(recipe)
        let decoded = try codec.decode(data)

        #expect(decoded == recipe)
    }

    @Test
    func exportsShareableRecipeJSONFromAppShortcuts() throws {
        let shortcuts = [
            AppShortcut(
                appName: "IINA",
                bundleIdentifier: "com.colliderli.iina",
                keyEquivalent: "i",
                modifierFlags: ["command", "option"],
                isEnabled: false
            )
        ]

        let codec = WinkRecipeCodec()
        let data = try codec.encode(shortcuts: shortcuts)
        let decoded = try codec.decode(data)

        #expect(decoded.shortcuts == [
            WinkRecipeShortcut(
                appName: "IINA",
                bundleIdentifier: "com.colliderli.iina",
                keyEquivalent: "i",
                modifierFlags: ["command", "option"],
                isEnabled: false
            )
        ])
    }

    @Test
    func rejectsUnsupportedSchemaVersion() {
        let payload = Data(
            """
            {
              "schemaVersion": 2,
              "shortcuts": []
            }
            """.utf8
        )

        let codec = WinkRecipeCodec()

        #expect(throws: WinkRecipeCodec.Error.self) {
            try codec.decode(payload)
        }
    }
}
