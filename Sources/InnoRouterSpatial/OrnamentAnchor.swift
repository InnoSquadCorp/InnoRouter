/// Placement hint for an InnoRouter-managed ornament.
///
/// SwiftUI's `ornament(attachmentAnchor:contentAlignment:ornament:)`
/// modifier accepts a `SceneAttachmentAnchor.Scene` value plus an
/// `Alignment`. Both live in SwiftUI, so ``InnoRouterSpatial`` models them
/// with its own plain value types and lets the view modifier translate.
/// The result: ornament placement can be stored, serialised, and reasoned
/// about on any platform InnoRouter compiles for.
public struct OrnamentAnchor: Sendable, Hashable, Codable {
    /// Named attachment points that correspond to
    /// `SceneAttachmentAnchor.Scene`'s pre-defined cases.
    public enum Anchor: Sendable, Hashable, Codable {
        case bottom
        case top
        case leading
        case trailing
        case bottomLeading
        case bottomTrailing
        case topLeading
        case topTrailing
    }

    /// Content alignment within the ornament, matching SwiftUI's
    /// `Alignment` positional cases.
    public enum Alignment: Sendable, Hashable, Codable {
        case center
        case bottom
        case top
        case leading
        case trailing
        case bottomLeading
        case bottomTrailing
        case topLeading
        case topTrailing
    }

    /// Where the ornament attaches relative to its scene.
    public let anchor: Anchor

    /// How the ornament's content is aligned inside the ornament.
    public let alignment: Alignment

    /// Creates an ornament anchor.
    public init(anchor: Anchor, alignment: Alignment = .center) {
        self.anchor = anchor
        self.alignment = alignment
    }
}
