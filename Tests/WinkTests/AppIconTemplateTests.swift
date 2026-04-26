import AppKit
import Testing
@testable import Wink

@Suite("App icon template")
struct AppIconTemplateTests {
    @Test
    func menuBarTemplateAssetLoadsAsTemplateSizedForStatusBar() {
        let image = WinkMenuBarTemplateAsset.image

        #expect(image.isTemplate == true)
        #expect(abs(image.size.width - 16) < 0.01)
        #expect(abs(image.size.height - 16) < 0.01)
        #expect(image.representations.isEmpty == false)
    }

    @Test
    func menuBarTemplateHasEnoughVisibleAlphaToAvoidBlankSlot() throws {
        let image = WinkMenuBarTemplateAsset.image
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let bounds = try #require(nonTransparentBounds(in: bitmap))

        #expect(Int(bounds.width) >= bitmap.pixelsWide * 3 / 4)
        #expect(Int(bounds.height) >= bitmap.pixelsHigh * 5 / 8)
    }
}

private func nonTransparentBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = -1
    var maxY = -1

    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y),
                  color.alphaComponent > 0.05
            else {
                continue
            }

            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else {
        return nil
    }

    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}
