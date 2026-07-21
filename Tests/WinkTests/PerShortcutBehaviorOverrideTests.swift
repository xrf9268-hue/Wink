import Foundation
import Testing
@testable import Wink

// MARK: - Model round-trip and lenient decoding

@Test func appShortcutOverrideRoundTripsThroughJSON() throws {
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option"],
        frontmostBehaviorOverride: .focus
    )

    let data = try JSONEncoder().encode(shortcut)
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: data)
    #expect(decoded == shortcut)
    #expect(decoded.frontmostBehaviorOverride == .focus)
}

@Test func nilOverrideOmitsKeyForOlderBuilds() throws {
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command"]
    )

    let json = String(decoding: try JSONEncoder().encode(shortcut), as: UTF8.self)
    #expect(!json.contains("frontmostBehaviorOverride"))
}

@Test func unknownOverrideValueDecodesLenientlyWithoutFailingTheFile() throws {
    // A newer build wrote a behavior this build doesn't know. The strict
    // shortcuts.json loader quarantines the whole file on any decode
    // error, so the unknown value must degrade to nil, never throw.
    let json = """
    [
      {"id":"11111111-1111-1111-1111-111111111111","appName":"Safari",
       "bundleIdentifier":"com.apple.Safari","keyEquivalent":"s",
       "modifierFlags":["command"],"isEnabled":true,
       "frontmostBehaviorOverride":"someFutureBehavior"},
      {"id":"22222222-2222-2222-2222-222222222222","appName":"Mail",
       "bundleIdentifier":"com.apple.mail","keyEquivalent":"m",
       "modifierFlags":["command"],"isEnabled":true,
       "frontmostBehaviorOverride":"cycleWindows"}
    ]
    """
    let decoded = try JSONDecoder().decode([AppShortcut].self, from: Data(json.utf8))
    #expect(decoded.count == 2)
    #expect(decoded[0].frontmostBehaviorOverride == nil)
    #expect(decoded[1].frontmostBehaviorOverride == .cycleWindows)
}

@Test func nonStringOverrideValueDecodesLenientlyToNil() throws {
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","appName":"Safari",
     "bundleIdentifier":"com.apple.Safari","keyEquivalent":"s",
     "modifierFlags":["command"],"isEnabled":true,
     "frontmostBehaviorOverride":42}
    """
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    #expect(decoded.frontmostBehaviorOverride == nil)
}

// MARK: - Recipe export/import

@Test func recipeExportImportPreservesOverride() throws {
    let codec = WinkRecipeCodec()
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option"],
        frontmostBehaviorOverride: .cycleWindows
    )

    let data = try codec.encode(shortcuts: [shortcut])
    let recipe = try codec.decode(data)
    #expect(recipe.shortcuts.first?.frontmostBehaviorOverride == "cycleWindows")
    #expect(recipe.shortcuts.first?.behaviorOverride == .cycleWindows)

    let planner = WinkRecipeImportPlanner()
    let installed = [AppEntry(id: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))]
    let plan = planner.planImport(recipe: recipe, existingShortcuts: [], installedApps: installed)
    let imported = try #require(plan.readyEntries.first?.imported.makeAppShortcut())
    #expect(imported.frontmostBehaviorOverride == .cycleWindows)
}

@Test func legacyRecipeWithoutOverrideFieldStillImports() throws {
    let json = """
    {"schemaVersion":1,"shortcuts":[
      {"appName":"Safari","bundleIdentifier":"com.apple.Safari",
       "keyEquivalent":"s","modifierFlags":["command"],"isEnabled":true}
    ]}
    """
    let recipe = try WinkRecipeCodec().decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.behaviorOverride == nil)
}

@Test func recipeWithUnknownOverrideValueImportsAsFollowGlobal() throws {
    let json = """
    {"schemaVersion":1,"shortcuts":[
      {"appName":"Safari","bundleIdentifier":"com.apple.Safari",
       "keyEquivalent":"s","modifierFlags":["command"],"isEnabled":true,
       "frontmostBehaviorOverride":"someFutureBehavior"}
    ]}
    """
    let recipe = try WinkRecipeCodec().decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.frontmostBehaviorOverride == "someFutureBehavior")
    #expect(recipe.shortcuts.first?.behaviorOverride == nil)
}
