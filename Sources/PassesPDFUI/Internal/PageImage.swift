#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import SwiftUI

/// Holds a decoded page bitmap and its source-page aspect ratio. The image
/// shape (`CGImage`) is the iOS analogue of Android's `Bitmap` /
/// `ImageBitmap`: an immutable pixel container that `SwiftUI.Image` can
/// draw without copying. Sendable so it can cross the actor boundary into
/// `@MainActor` view state. `CGImage` is reference-typed but is documented
/// as safe to share across threads after creation, so the `@unchecked`
/// conformance reflects what the platform already guarantees.
struct PageImage: @unchecked Sendable {
    let cgImage: CGImage
    let pageAspect: Float

    var image: Image {
        Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

#endif
