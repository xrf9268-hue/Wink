import AppKit
import DeveloperToolsSupport
import SwiftUI

struct WinkMenuBarSceneDescriptor: Equatable {
    let title: String
    let imageName: String
    let usesWindowStyle: Bool
    let isInserted: Bool
    let usesCustomTemplateLabel: Bool
}

enum WinkMenuBarTemplateAsset {
    static let name = "MenuBarTemplate"
    static let imageResource = ImageResource(name: name, bundle: .module)

    static var image: NSImage {
        let image = NSImage(resource: imageResource)
        image.isTemplate = true
        return image
    }
}

private enum WinkMenuBarSceneConstants {
    static let title = "Wink"
    static let templatePointSize: CGFloat = 18
}

struct WinkMenuBarScene<Content: View>: Scene {
    @Binding private var isInserted: Bool
    @ViewBuilder private let content: () -> Content

    init(
        isInserted: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isInserted = isInserted
        self.content = content
    }

    nonisolated static func descriptor(isInserted: Bool) -> WinkMenuBarSceneDescriptor {
        WinkMenuBarSceneDescriptor(
            title: WinkMenuBarSceneConstants.title,
            imageName: WinkMenuBarTemplateAsset.name,
            usesWindowStyle: true,
            isInserted: isInserted,
            usesCustomTemplateLabel: true
        )
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $isInserted) {
            content()
        } label: {
            WinkMenuBarTemplateLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct WinkMenuBarTemplateLabel: View {
    var body: some View {
        Image(nsImage: WinkMenuBarTemplateAsset.image)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: WinkMenuBarSceneConstants.templatePointSize,
                height: WinkMenuBarSceneConstants.templatePointSize
            )
            .accessibilityLabel(Text(WinkMenuBarSceneConstants.title))
    }
}
