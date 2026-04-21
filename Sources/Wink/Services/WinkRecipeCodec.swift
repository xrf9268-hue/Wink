import Foundation

struct WinkRecipeCodec {
    enum Error: Swift.Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        encoder: JSONEncoder = WinkRecipeCodec.makeEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    func encode(_ recipe: WinkRecipe) throws -> Data {
        try encoder.encode(recipe)
    }

    func encode(shortcuts: [AppShortcut]) throws -> Data {
        try encode(WinkRecipe(shortcuts: shortcuts))
    }

    func decode(_ data: Data) throws -> WinkRecipe {
        let recipe = try decoder.decode(WinkRecipe.self, from: data)
        guard recipe.schemaVersion == WinkRecipe.currentSchemaVersion else {
            throw Error.unsupportedSchemaVersion(recipe.schemaVersion)
        }
        return recipe
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
