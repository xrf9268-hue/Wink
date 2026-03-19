import CoreGraphics

struct KeySymbolMapper {
    func keyEquivalent(for keyCode: CGKeyCode) -> String? {
        KeyMatcher.codeToKeyEquivalent[keyCode]
    }
}
