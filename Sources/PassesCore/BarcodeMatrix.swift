import Foundation

/// Encoded barcode as a grid of monochrome modules. `true` means "dark module"
/// (printed/black); `false` means "light module" (background/white). Coordinates are
/// zero-based with the origin at the top-left; `(0, 0)` is the top-left module.
///
/// Opaque wrapper: the underlying storage layout is an implementation detail so the encoder
/// can swap libraries (or move to a packed-bitset representation) without forcing every
/// renderer to re-learn the matrix. Consumers iterate via `isSet` only.
///
/// Construction is `internal` so this type is mintable only by the kernel's encoder path —
/// external callers cannot fabricate a matrix that misrepresents what the encoder produced.
/// The value type is structurally compared on `(width, height, modules)`; two encoders that
/// produced byte-identical output compare equal even when the underlying arrays differ.
///
/// Pure data, no behavior. A third-party `BitMatrix` type is intentionally NOT exposed on
/// this surface — that would put a third-party type on the kernel's public API and
/// complicate any future encoder swap.
public final class BarcodeMatrix: @unchecked Sendable, Equatable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    private let modules: [Bool]

    internal init(width: Int, height: Int, modules: [Bool]) {
        precondition(width > 0, "width must be positive, was \(width)")
        precondition(height > 0, "height must be positive, was \(height)")
        precondition(
            modules.count == width * height,
            "modules size \(modules.count) does not match width * height = \(width * height)"
        )
        self.width = width
        self.height = height
        self.modules = modules
    }

    public func isSet(x: Int, y: Int) -> Bool {
        precondition((0..<width).contains(x), "x=\(x) out of bounds [0, \(width))")
        precondition((0..<height).contains(y), "y=\(y) out of bounds [0, \(height))")
        return modules[y * width + x]
    }

    public static func == (lhs: BarcodeMatrix, rhs: BarcodeMatrix) -> Bool {
        if lhs === rhs { return true }
        return lhs.width == rhs.width && lhs.height == rhs.height && lhs.modules == rhs.modules
    }

    public var description: String { "BarcodeMatrix(width=\(width), height=\(height))" }
}
