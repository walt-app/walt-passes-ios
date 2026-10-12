import SwiftUI

/// The ONE pinch-zoom/pan/double-tap primitive both full-screen arms compose
/// (mirror of Android's `ZoomableImage`, wpass-pl7.4). Zoom is purely
/// view-side: a `scaleEffect` over already-decoded pixels; nothing re-decodes
/// on gesture.
///
/// THE CLIP LESSON (wpass-pl7.4 review), translated to SwiftUI semantics:
/// the scaled layer draws outside its layout bounds, so the ONE clip below is
/// framed to the SLOT (`proxy.size`) — the clip rect is the unscaled slot and
/// can never follow the content. Compose's exact mistake
/// (`graphicsLayer(clip=true)` scaling the clip shape) has no direct SwiftUI
/// form — `.clipped()` clips to layout bounds, which `.scaleEffect` does not
/// change — but a clip on a content-sized layer instead of the slot-framed
/// container recreates the Android overdraw of the trust-caption dock the
/// moment content stops filling the slot. `ZoomableContentTests` pins the
/// inventory (every `scaleEffect` in this module lives here, one clip,
/// slot-framed).
///
/// Pan is clamped to ±((scale-1) × slot/2) per axis — the content edge never
/// pans past the slot edge — and resets with the double-tap zoom-out.
///
/// The primitive owns its accessibility: one image element with `label`, its
/// zoom level as the value, and a VoiceOver zoom action driving the same scale.
struct ZoomableContent<Content: View>: View {
    let label: Text
    let content: Content

    init(label: Text, @ViewBuilder content: () -> Content) {
        self.init(label: label, initialScale: Self.minScale, initialOffset: .zero, content: content)
    }

    /// Test seam: start already zoomed and panned.
    init(
        label: Text, initialScale: CGFloat, initialOffset: CGSize, @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.content = content()
        _scale = State(initialValue: initialScale)
        _lastScale = State(initialValue: initialScale)
        _offset = State(initialValue: initialOffset)
        _lastOffset = State(initialValue: initialOffset)
    }

    @State private var scale: CGFloat
    @State private var lastScale: CGFloat
    @State private var offset: CGSize
    @State private var lastOffset: CGSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Framed to the slot, so the clip rect is the unscaled slot.
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = Self.clampScale(lastScale * value)
                        offset = Self.clampOffset(offset, scale: scale, slot: proxy.size)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        lastOffset = offset
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > Self.minScale else { return }
                        let proposed = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                        offset = Self.clampOffset(proposed, scale: scale, slot: proxy.size)
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > Self.minScale {
                        scale = Self.minScale
                        lastScale = Self.minScale
                    } else {
                        scale = Self.doubleTapScale
                        lastScale = Self.doubleTapScale
                    }
                    // Both directions re-center (Android parity) — keeps the
                    // offset invariant local instead of provable-at-a-distance.
                    offset = .zero
                    lastOffset = .zero
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .accessibilityValue(Text(Double(scale), format: .percent.precision(.fractionLength(0))))
            .accessibilityZoomAction { action in
                scale = Self.accessibilityZoomed(scale, zoomIn: action.direction == .zoomIn)
                lastScale = scale
                // Zooming out shrinks the pan bound; at 1x this re-centers.
                offset = Self.clampOffset(offset, scale: scale, slot: proxy.size)
                lastOffset = offset
            }
        }
    }

    /// Mirror of Android's `DEFAULT_MIN_SCALE` / `DEFAULT_MAX_SCALE` /
    /// `DEFAULT_DOUBLE_TAP_SCALE`.
    static var minScale: CGFloat { 1 }
    static var maxScale: CGFloat { 5 }
    static var doubleTapScale: CGFloat { 2 }
    static var accessibilityZoomStep: CGFloat { 1 }

    static func accessibilityZoomed(_ scale: CGFloat, zoomIn: Bool) -> CGFloat {
        clampScale(zoomIn ? scale + accessibilityZoomStep : scale - accessibilityZoomStep)
    }

    static func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    /// ±((scale-1) × slot/2) per axis: at 1x the content is pinned centered;
    /// zoomed, its edges never pan past the slot edge.
    static func clampOffset(_ proposed: CGSize, scale: CGFloat, slot: CGSize) -> CGSize {
        let boundX = max(0, (scale - 1) * slot.width / 2)
        let boundY = max(0, (scale - 1) * slot.height / 2)
        return CGSize(
            width: min(max(proposed.width, -boundX), boundX),
            height: min(max(proposed.height, -boundY), boundY)
        )
    }
}
