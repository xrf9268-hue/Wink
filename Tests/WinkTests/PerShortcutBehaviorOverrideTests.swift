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

// MARK: - Frontmost-app target (model + recipe)

@Test func targetFieldRoundTripsAndDecodesLeniently() throws {
    let shortcut = AppShortcut(
        appName: AppShortcut.frontmostTargetStableName,
        bundleIdentifier: AppShortcut.frontmostTargetSentinelBundleIdentifier,
        keyEquivalent: "`",
        modifierFlags: ["command"],
        target: .frontmostApp
    )
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: JSONEncoder().encode(shortcut))
    #expect(decoded.target == .frontmostApp)
    #expect(decoded.isFrontmostAppTarget)

    // Unknown target from a newer build degrades to nil (.app semantics);
    // the sentinel bundle keeps the row unavailable rather than misfiring.
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","appName":"X",
     "bundleIdentifier":"wink.target.frontmost-app","keyEquivalent":"x",
     "modifierFlags":["command"],"isEnabled":true,"target":"someFutureTarget"}
    """
    let lenient = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    #expect(lenient.target == nil)
}

// MARK: - Search-palette trigger target (#356)

@Test func searchPaletteTargetRoundTripsAndDecodesLeniently() throws {
    let shortcut = AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: JSONEncoder().encode(shortcut))
    #expect(decoded.target == .searchPalette)
    #expect(decoded.isSearchPaletteTarget)
    #expect(!decoded.isFrontmostAppTarget)

    // A build that predates `.searchPalette` (or any hand-edited/future
    // rawValue) decodes leniently to nil — same guarantee the frontmost
    // pseudo-target already relies on, exercised here against this specific
    // sentinel bundle so a regression in either target's leniency shows up
    // independently.
    let json = """
    {"id":"22222222-2222-2222-2222-222222222222","appName":"Search Palette",
     "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
     "modifierFlags":["command","option"],"isEnabled":true,"target":"someFutureTarget"}
    """
    let lenient = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    #expect(lenient.target == nil)
    #expect(!lenient.isSearchPaletteTarget)
}

@Test func recipeWithFrontmostTargetExportsAsV2AndPlansAvailable() throws {
    let codec = WinkRecipeCodec()
    let pseudo = AppShortcut(
        appName: AppShortcut.frontmostTargetStableName,
        bundleIdentifier: AppShortcut.frontmostTargetSentinelBundleIdentifier,
        keyEquivalent: "`",
        modifierFlags: ["command"],
        target: .frontmostApp
    )

    let recipe = try codec.decode(try codec.encode(shortcuts: [pseudo]))
    #expect(recipe.schemaVersion == WinkRecipe.frontmostTargetSchemaVersion)

    // No installed app matches the sentinel — the planner must still plan
    // it as ready, preserving identity and target.
    let plan = WinkRecipeImportPlanner().planImport(recipe: recipe, existingShortcuts: [], installedApps: [])
    let imported = try #require(plan.readyEntries.first?.imported.makeAppShortcut())
    #expect(imported.target == .frontmostApp)
    #expect(imported.bundleIdentifier == AppShortcut.frontmostTargetSentinelBundleIdentifier)
    // The planner must persist the locale-stable name, not a localized
    // label, regardless of what the source recipe's own appName said.
    #expect(imported.appName == AppShortcut.frontmostTargetStableName)
}

@Test func plainRecipeStillExportsAsV1() throws {
    let codec = WinkRecipeCodec()
    let plain = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command"]
    )
    let recipe = try codec.decode(try codec.encode(shortcuts: [plain]))
    #expect(recipe.schemaVersion == WinkRecipe.currentSchemaVersion)
}

@Test func recipeExportImportPreservesHoldAction() throws {
    let codec = WinkRecipeCodec()
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option"],
        holdAction: .windowPicker
    )

    let data = try codec.encode(shortcuts: [shortcut])
    let recipe = try codec.decode(data)
    #expect(recipe.shortcuts.first?.holdAction == "windowPicker")
    #expect(recipe.shortcuts.first?.holdActionValue == .windowPicker)

    let planner = WinkRecipeImportPlanner()
    let installed = [AppEntry(id: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))]
    let plan = planner.planImport(recipe: recipe, existingShortcuts: [], installedApps: installed)
    let imported = try #require(plan.readyEntries.first?.imported.makeAppShortcut())
    #expect(imported.holdAction == .windowPicker)
}

@Test func recipeWithUnknownHoldActionImportsAsNone() throws {
    let json = """
    {"schemaVersion":1,"shortcuts":[
      {"appName":"Safari","bundleIdentifier":"com.apple.Safari",
       "keyEquivalent":"s","modifierFlags":["command"],"isEnabled":true,
       "holdAction":"someFutureAction"}
    ]}
    """
    let recipe = try WinkRecipeCodec().decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.holdAction == "someFutureAction")
    #expect(recipe.shortcuts.first?.holdActionValue == nil)
}

@Test func recipeWithWrongTypedOptionalFieldDegradesInsteadOfRejecting() throws {
    // A wrong-TYPE optional raw field (hand-edited or future schema) must
    // degrade to nil like shortcuts.json does, not quarantine the recipe.
    let json = """
    {"schemaVersion":1,"shortcuts":[
      {"appName":"Safari","bundleIdentifier":"com.apple.Safari",
       "keyEquivalent":"s","modifierFlags":["command"],"isEnabled":true,
       "holdAction":42,"frontmostBehaviorOverride":7}
    ]}
    """
    let recipe = try WinkRecipeCodec().decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.holdActionValue == nil)
    #expect(recipe.shortcuts.first?.behaviorOverride == nil)
    #expect(recipe.shortcuts.first?.appName == "Safari")
}

// MARK: - Sentinel target backfill (#404)

@Test func missingTargetBackfillsFromKnownSentinelBundles() throws {
    // Hand-authored or third-party files may name a sentinel bundle without
    // the explicit "target" field. Known sentinels are unambiguous — the
    // row must decode into a working trigger, not a silently dead one.
    let json = """
    [
      {"id":"11111111-1111-1111-1111-111111111111","appName":"Search Palette",
       "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
       "modifierFlags":["control","option","shift","command"],"isEnabled":true},
      {"id":"22222222-2222-2222-2222-222222222222","appName":"Current App",
       "bundleIdentifier":"wink.target.frontmost-app","keyEquivalent":"g",
       "modifierFlags":["control","option","shift","command"],"isEnabled":true}
    ]
    """
    let decoded = try JSONDecoder().decode([AppShortcut].self, from: Data(json.utf8))
    #expect(decoded[0].target == .searchPalette)
    #expect(decoded[0].isSearchPaletteTarget)
    #expect(decoded[1].target == .frontmostApp)
    #expect(decoded[1].isFrontmostAppTarget)
}

@Test func missingTargetStaysNilForOrdinaryBundles() throws {
    let json = """
    [
      {"id":"11111111-1111-1111-1111-111111111111","appName":"Safari",
       "bundleIdentifier":"com.apple.Safari","keyEquivalent":"s",
       "modifierFlags":["command"],"isEnabled":true}
    ]
    """
    let decoded = try JSONDecoder().decode([AppShortcut].self, from: Data(json.utf8))
    #expect(decoded[0].target == nil)
    #expect(!decoded[0].isSearchPaletteTarget)
    #expect(!decoded[0].isFrontmostAppTarget)
}

@Test func unknownFutureSentinelStaysUnavailableNotMisfired() throws {
    // A future build's sentinel this build doesn't know must keep the
    // pre-existing degrade-to-unavailable behavior, never guess a kind.
    let json = """
    [
      {"id":"11111111-1111-1111-1111-111111111111","appName":"Window Switcher",
       "bundleIdentifier":"wink.target.window-switcher","keyEquivalent":"w",
       "modifierFlags":["control","option","shift","command"],"isEnabled":true,
       "target":"windowSwitcher"}
    ]
    """
    let decoded = try JSONDecoder().decode([AppShortcut].self, from: Data(json.utf8))
    #expect(decoded[0].target == nil)
    #expect(!decoded[0].isSearchPaletteTarget)
    #expect(!decoded[0].isFrontmostAppTarget)
}

@Test func unknownTargetValueSurvivesReencodeWithoutArming() throws {
    // The round-trip hole: unknown value → nil → key omitted on save →
    // backfilled as a LIVE trigger on the next load. The raw string must
    // re-encode verbatim so the row stays gated forever.
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","appName":"Search Palette",
     "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
     "modifierFlags":["command"],"isEnabled":true,"target":"someFutureTarget"}
    """
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    #expect(decoded.target == nil)
    #expect(!decoded.isSearchPaletteTarget)

    let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(reencoded.contains("someFutureTarget"))

    let secondLoad = try JSONDecoder().decode(AppShortcut.self, from: Data(reencoded.utf8))
    #expect(secondLoad.target == nil)
    #expect(!secondLoad.isSearchPaletteTarget)
}

@Test func presentNullTargetOnSentinelStaysDisarmedAcrossSaves() throws {
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","appName":"Search Palette",
     "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
     "modifierFlags":["command"],"isEnabled":true,"target":null}
    """
    let decoded = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    #expect(decoded.target == nil)
    #expect(!decoded.isSearchPaletteTarget)

    // The null must survive re-encoding — an omitted key would be
    // backfilled (armed) by the next load.
    let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(reencoded.contains("\"target\":null"))

    let secondLoad = try JSONDecoder().decode(AppShortcut.self, from: Data(reencoded.utf8))
    #expect(secondLoad.target == nil)
    #expect(!secondLoad.isSearchPaletteTarget)
}

@Test func recipeSentinelWithoutTargetResolvesAndStaysExcludedFromImport() throws {
    // A hand-authored recipe naming the palette sentinel without "target"
    // must resolve to .searchPalette so the planner's device-local
    // exclusion still catches it — never import as a hidden armed trigger.
    let json = """
    {"schemaVersion":2,"shortcuts":[
      {"appName":"Search Palette","bundleIdentifier":"wink.target.search-palette",
       "keyEquivalent":"space","modifierFlags":["command","option"],"isEnabled":true}
    ]}
    """
    let recipe = try WinkRecipeCodec().decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.shortcutTarget == .searchPalette)

    let plan = WinkRecipeImportPlanner().planImport(
        recipe: recipe,
        existingShortcuts: [],
        installedApps: []
    )
    #expect(plan.entries.isEmpty)
}

@Test func recipeNullTargetOnSentinelStaysGatedAndRoundTrips() throws {
    let json = """
    {"schemaVersion":2,"shortcuts":[
      {"appName":"Current App","bundleIdentifier":"wink.target.frontmost-app",
       "keyEquivalent":"g","modifierFlags":["command"],"isEnabled":true,"target":null}
    ]}
    """
    let codec = WinkRecipeCodec()
    let recipe = try codec.decode(Data(json.utf8))
    #expect(recipe.shortcuts.first?.shortcutTarget == nil)

    // The gate must survive a re-encode: explicit null, never an absent key.
    let reencoded = String(decoding: try codec.encode(shortcuts: []), as: UTF8.self)
    _ = reencoded
    let reencodedRecipe = String(
        decoding: try JSONEncoder().encode(recipe),
        as: UTF8.self
    )
    #expect(reencodedRecipe.contains("\"target\":null"))
    let secondLoad = try JSONDecoder().decode(WinkRecipe.self, from: Data(reencodedRecipe.utf8))
    #expect(secondLoad.shortcuts.first?.shortcutTarget == nil)
}

@Test func exportingAGatedShortcutKeepsTheGateInTheRecipe() throws {
    // A shortcuts.json row with an unknown target string, exported to a
    // recipe, must carry the unknown string — importing it elsewhere may
    // never backfill and arm the sentinel.
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","appName":"Search Palette",
     "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
     "modifierFlags":["command"],"isEnabled":true,"target":"someFutureTarget"}
    """
    let gated = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
    let recipeShortcut = WinkRecipeShortcut(gated)
    #expect(recipeShortcut.target == "someFutureTarget")
    #expect(recipeShortcut.shortcutTarget == nil)
}

@Test func explicitTargetStillWinsOverBackfill() throws {
    let json = """
    [
      {"id":"11111111-1111-1111-1111-111111111111","appName":"Search Palette",
       "bundleIdentifier":"wink.target.search-palette","keyEquivalent":"space",
       "modifierFlags":["control","option","shift","command"],"isEnabled":true,
       "target":"searchPalette"}
    ]
    """
    let decoded = try JSONDecoder().decode([AppShortcut].self, from: Data(json.utf8))
    #expect(decoded[0].target == .searchPalette)
}
