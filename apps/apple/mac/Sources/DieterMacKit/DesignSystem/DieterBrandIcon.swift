import AppKit
import SwiftUI

struct DieterBrandIcon: View {
    let size: CGFloat

    // The app bundle carries apps/apple/mac/Resources under their own names:
    // the monochrome palette icon and the monochrome favicon.
    private static let appImage: NSImage? = {
        guard
            let url = Bundle.main.url(
                forResource: "monochrome", withExtension: "png", subdirectory: "PaletteIcons")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    private static let faviconImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "DieterMonochromeFavicon", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = size < 32 ? Self.faviconImage : Self.appImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DieterTheme.shell)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
