package extension RouterGraphSnapshotLimits {
    /// Preserve every stricter source limit when adapting between formats.
    func intersecting(_ other: Self) throws -> Self {
        try .init(
            maximumEncodedBytes: min(maximumEncodedBytes, other.maximumEncodedBytes),
            maximumPayloadBytes: min(maximumPayloadBytes, other.maximumPayloadBytes),
            maximumRoutePayloadBytes: min(maximumRoutePayloadBytes, other.maximumRoutePayloadBytes),
            maximumJSONDepth: min(maximumJSONDepth, other.maximumJSONDepth),
            maximumJSONTokens: min(maximumJSONTokens, other.maximumJSONTokens),
            maximumNodes: min(maximumNodes, other.maximumNodes),
            maximumRoutes: min(maximumRoutes, other.maximumRoutes),
            maximumPresentations: min(maximumPresentations, other.maximumPresentations),
            maximumGraphDepth: min(maximumGraphDepth, other.maximumGraphDepth),
            maximumStackPath: min(maximumStackPath, other.maximumStackPath),
            maximumPresentationDepth: min(maximumPresentationDepth, other.maximumPresentationDepth),
            maximumWindows: min(maximumWindows, other.maximumWindows)
        )
    }
}

package extension RouterGraphSnapshotLimits {
    func limitingJSONDepth(to depth: Int) throws -> Self {
        try .init(
            maximumEncodedBytes: maximumEncodedBytes, maximumPayloadBytes: maximumPayloadBytes,
            maximumRoutePayloadBytes: maximumRoutePayloadBytes, maximumJSONDepth: min(maximumJSONDepth, depth),
            maximumJSONTokens: maximumJSONTokens, maximumNodes: maximumNodes, maximumRoutes: maximumRoutes,
            maximumPresentations: maximumPresentations, maximumGraphDepth: maximumGraphDepth,
            maximumStackPath: maximumStackPath, maximumPresentationDepth: maximumPresentationDepth,
            maximumWindows: maximumWindows
        )
    }
}
