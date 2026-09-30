import Foundation

func renderRouterDeepLinkMembers(
    from specification: RouterDeepLinkSpecification,
    access: String,
    declarationNamespace: String,
    features: RouterFeatureSpecification? = nil
) -> String {
    if features?.items.isEmpty ?? true {
        return renderStandaloneRouterDeepLinkMembers(
            from: specification,
            access: access,
            declarationNamespace: declarationNamespace
        )
    }
    let mappings = specification.items
        .map { indentContinuationLines(renderDeepLinkMapping($0), by: 8) }
        .joined(separator: "\n        ")
    let schemes = specification.schemes.map(swiftStringLiteral).joined(separator: ", ")
    let hosts = specification.hosts.map(swiftStringLiteral).joined(separator: ", ")
    let featureItems = features?.items ?? []
    var renderedURLCases = specification.items.map {
        renderDeepLinkURLCase(
            $0,
            allowedSchemes: specification.schemes,
            allowedHosts: specification.hosts
        )
    }
    renderedURLCases.append(contentsOf: featureItems.map(renderFeatureURLCase))
    if specification.hasUnmappedCases {
        renderedURLCases.append("default:\n    return nil")
    }
    let renderingCases = renderedURLCases
        .map { indentContinuationLines($0, by: 8) }
        .joined(separator: "\n        ")

    let featureResolution = renderFeatureResolution(featureItems)
    let catalog = renderFeatureDeepLinkCatalog(
        from: specification,
        access: access,
        declarationNamespace: declarationNamespace,
        featureItems: featureItems
    )

    return """
    \(catalog)\(access) static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
        InnoRouterDeepLink.DeepLinkFeatureRuntime.resolve(Self.self, url: url) {
            var candidates: [Self] = []
            let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                configuration: .init(diagnosticsMode: .disabled)
            ) {
                \(indentEveryLine(mappings, by: 4))
            }
            if url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  let scheme = url.scheme,
                  [\(schemes)].contains(where: {
                      $0.caseInsensitiveCompare(scheme) == .orderedSame
                  }),
                  let host = url.host,
                  [\(hosts)].contains(where: {
                      $0.caseInsensitiveCompare(host) == .orderedSame
                  }),
                  let route = matcher.match(url) {
                candidates.append(route)
            }
    \(indentEveryLine(featureResolution, by: 8))
            guard candidates.count == 1 else { return nil }
            return candidates[0]
        }
    }

    \(access) func deepLinkURL(
        origin: InnoRouterDeepLink.DeepLinkOrigin
    ) -> Foundation.URL? {
        InnoRouterDeepLink.DeepLinkFeatureRuntime.url(for: self, origin: origin) {
            switch self {
        \(indentEveryLine(renderingCases, by: 4))
            }
        }
    }
    """
}

private func renderFeatureDeepLinkCatalog(
    from specification: RouterDeepLinkSpecification,
    access: String,
    declarationNamespace: String,
    featureItems: [RouterFeatureItem]
) -> String {
    let schemes = specification.schemes.map(swiftStringLiteral).joined(separator: ", ")
    let hosts = specification.hosts.map(swiftStringLiteral).joined(separator: ", ")
    let catalogEntries = specification.items.map {
        renderDeepLinkCatalogEntry($0, declarationNamespace: declarationNamespace)
    }
        .map { indentContinuationLines($0, by: 8) }
        .joined(separator: "\n        ")
    let featureCatalogMerges = renderFeatureCatalogMerges(
        featureItems,
        declarationNamespace: declarationNamespace
    )
    var catalogCaseNames = specification.items.map {
        "case .\($0.caseName):\n    return \(swiftStringLiteral($0.caseName))"
    }
    catalogCaseNames.append(contentsOf: featureItems.map(renderFeatureCatalogCaseName))
    if specification.hasUnmappedCases {
        catalogCaseNames.append("default:\n    return nil")
    }
    let purity = featureItems.map {
        "InnoRouterDeepLink.DeepLinkFeatureRuntime.supportsPureExplanation(for: \($0.childType).self)"
    }.joined(separator: " && ")

    return """
    \(access) static var supportsPureDeepLinkExplanation: Swift.Bool {
        InnoRouterDeepLink.DeepLinkFeatureRuntime.supportsPureExplanation(for: Self.self) {
            true\(purity.isEmpty ? "" : " && " + purity)
        }
    }

    \(access) static var deepLinkCatalog: InnoRouterDeepLink.DeepLinkRouteCatalog {
        InnoRouterDeepLink.DeepLinkFeatureRuntime.catalog(for: Self.self) {
            var result = InnoRouterDeepLink.DeepLinkRouteCatalog(
                schemes: [\(schemes)],
                hosts: [\(hosts)],
                entries: [
                    \(indentEveryLine(catalogEntries, by: 4))
                ]
            )
    \(indentEveryLine(featureCatalogMerges, by: 8))
            return result
        }
    }

    \(access) static func deepLinkCatalogCaseName(for route: Self) -> Swift.String? {
        InnoRouterDeepLink.DeepLinkFeatureRuntime.caseName(for: route) {
            switch route {
        \(indentEveryLine(catalogCaseNames.joined(separator: "\n"), by: 12))
            }
        }
    }

    """
}

private func renderStandaloneRouterDeepLinkMembers(
    from specification: RouterDeepLinkSpecification,
    access: String,
    declarationNamespace: String
) -> String {
    let mappings = specification.items
        .map { indentContinuationLines(renderDeepLinkMapping($0), by: 8) }
        .joined(separator: "\n        ")
    let schemes = specification.schemes.map(swiftStringLiteral).joined(separator: ", ")
    let hosts = specification.hosts.map(swiftStringLiteral).joined(separator: ", ")
    let catalogEntries = specification.items.map {
        renderDeepLinkCatalogEntry($0, declarationNamespace: declarationNamespace)
    }
        .map { indentContinuationLines($0, by: 8) }
        .joined(separator: "\n        ")
    var renderedURLCases = specification.items.map { renderDeepLinkURLCase($0) }
    if specification.hasUnmappedCases {
        renderedURLCases.append("default:\n    return nil")
    }
    let renderingCases = renderedURLCases
        .map { indentContinuationLines($0, by: 8) }
        .joined(separator: "\n        ")
    let catalog = specification.generatesInspectorCatalog ? """
    \(access) static var supportsPureDeepLinkExplanation: Swift.Bool { true }

    \(access) static var deepLinkCatalog: InnoRouterDeepLink.DeepLinkRouteCatalog {
        InnoRouterDeepLink.DeepLinkRouteCatalog(
            schemes: [\(schemes)],
            hosts: [\(hosts)],
            entries: [
                \(catalogEntries)
            ]
        )
    }

    \(access) static func deepLinkCatalogCaseName(for route: Self) -> Swift.String? {
        switch route {
        \(indentEveryLine(renderDeepLinkCatalogCaseNames(specification), by: 8))
        }
    }

    """ : ""
    return """
    \(catalog)\(access) static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
        let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            \(mappings)
        }
        guard url.user == nil,
              url.password == nil,
              url.port == nil,
              let scheme = url.scheme,
              [\(schemes)].contains(where: {
                  $0.caseInsensitiveCompare(scheme) == .orderedSame
              }),
              let host = url.host,
              [\(hosts)].contains(where: {
                  $0.caseInsensitiveCompare(host) == .orderedSame
              }),
              let route = matcher.match(url) else {
            return nil
        }
        return route
    }

    \(access) func deepLinkURL(
        origin: InnoRouterDeepLink.DeepLinkOrigin
    ) -> Foundation.URL? {
        guard [\(schemes)].contains(origin.scheme),
              [\(hosts)].contains(origin.host) else {
            return nil
        }
        switch self {
        \(renderingCases)
        }
    }
    """
}

private func renderFeatureCatalogMerges(
    _ items: [RouterFeatureItem],
    declarationNamespace: String
) -> String {
    items.map { item in
        """
        result = result.merging(
            InnoRouterDeepLink.DeepLinkFeatureRuntime.catalog(for: \(item.childType).self)
                .namespaced(
                    declarationNamespace: \(swiftStringLiteral(declarationNamespace)),
                    featureID: \(swiftStringLiteral(item.id))
                )
        )
        """
    }.joined(separator: "\n")
}

private func renderFeatureResolution(_ items: [RouterFeatureItem]) -> String {
    items.map { item in
        let embed = item.emittedLabel.map { ".\(item.caseName)(\($0): child)" }
            ?? ".\(item.caseName)(child)"
        return """
        if let child = InnoRouterDeepLink.DeepLinkFeatureRuntime.resolve(
            \(item.childType).self,
            url: url
        ) {
            candidates.append(\(embed))
        }
        """
    }.joined(separator: "\n")
}

private func renderFeatureCatalogCaseName(_ item: RouterFeatureItem) -> String {
    """
    case .\(item.caseName)(let child):
        guard let childCase = InnoRouterDeepLink.DeepLinkFeatureRuntime.caseName(for: child) else {
            return nil
        }
        return \(swiftStringLiteral(item.id + ".")) + childCase
    """
}

private func renderFeatureURLCase(_ item: RouterFeatureItem) -> String {
    """
    case .\(item.caseName)(let child):
        guard let url = InnoRouterDeepLink.DeepLinkFeatureRuntime.url(
            for: child,
            origin: origin
        ), InnoRouterDeepLink.DeepLinkFeatureRuntime.resolve(Self.self, url: url) == self else {
            return nil
        }
        return url
    """
}

private func renderDeepLinkCatalogCaseNames(_ specification: RouterDeepLinkSpecification) -> String {
    var cases = specification.items.map {
        "case .\($0.caseName):\n    return \(swiftStringLiteral($0.caseName))"
    }
    if specification.hasUnmappedCases {
        cases.append("default:\n    return nil")
    }
    return cases.joined(separator: "\n")
}

func renderDeepLinkCatalogEntry(
    _ item: RouterDeepLinkItem,
    declarationNamespace: String
) -> String {
    let parameters = item.parameters.map { parameter in
        let source = item.pattern.split(separator: "/").contains(Substring(":\(parameter.label)"))
            ? ".path"
            : ".query"
        return """
        .init(
            name: \(swiftStringLiteral(parameter.label)),
            typeName: \(swiftStringLiteral(parameter.wrappedType)),
            source: \(source),
            isRequired: \(!parameter.isOptional),
            isApplicationConversionRequired: !InnoRouterDeepLink
                .DeepLinkParameterConversionSupport
                .isFrameworkOwned(\(parameter.wrappedType).self)
        )
        """
    }.map { indentContinuationLines($0, by: 8) }.joined(separator: "\n        ")
    let renderedParameters = parameters.isEmpty
        ? "[]"
        : "[\n            \(parameters)\n        ]"
    return """
    .init(
        declarationNamespace: \(swiftStringLiteral(declarationNamespace)),
        routeCase: \(swiftStringLiteral(item.caseName)),
        pattern: \(swiftStringLiteral(item.pattern)),
        parameters: \(renderedParameters)
    ),
    """
}

func renderDeepLinkURLCase(
    _ item: RouterDeepLinkItem,
    allowedSchemes: [String]? = nil,
    allowedHosts: [String]? = nil
) -> String {
    let binding: String
    if item.parameters.isEmpty {
        binding = "case .\(item.caseName):"
    } else {
        let values = item.parameters.indices
            .map { "deepLinkValue\($0)" }
            .joined(separator: ", ")
        binding = "case let .\(item.caseName)(\(values)):"
    }

    let originGuard: String
    if let allowedSchemes, let allowedHosts {
        let schemes = allowedSchemes.map(swiftStringLiteral).joined(separator: ", ")
        let hosts = allowedHosts.map(swiftStringLiteral).joined(separator: ", ")
        originGuard = """
        guard [\(schemes)].contains(origin.scheme),
              [\(hosts)].contains(origin.host) else {
            return nil
        }
        """
    } else {
        originGuard = ""
    }
    let guardedPrefix = originGuard.isEmpty
        ? ""
        : indentEveryLine(originGuard, by: 4) + "\n"

    if item.parameters.isEmpty {
        return """
        \(binding)
        \(guardedPrefix)    guard let url = InnoRouterDeepLink.DeepLinkURLBuilder.makeURL(
                origin: origin,
                pattern: \(swiftStringLiteral(item.pattern))
            ), InnoRouterDeepLink.DeepLinkFeatureRuntime.resolve(Self.self, url: url) == self else {
                return nil
            }
            return url
        """
    }

    let renderedParameters = item.parameters.enumerated().map { index, parameter in
        ".init(name: \(swiftStringLiteral(parameter.label)), value: deepLinkValue\(index))"
    }.joined(separator: ",\n")

    return """
    \(binding)
    \(guardedPrefix)    guard let url = InnoRouterDeepLink.DeepLinkURLBuilder.makeURL(
            origin: origin,
            pattern: \(swiftStringLiteral(item.pattern)),
            parameters: [
    \(indentEveryLine(renderedParameters, by: 12))
            ]
        ), InnoRouterDeepLink.DeepLinkFeatureRuntime.resolve(Self.self, url: url) == self else {
            return nil
        }
        return url
    """
}

func renderDeepLinkMapping(_ item: RouterDeepLinkItem) -> String {
    var statements = item.parameters.enumerated().map { index, parameter in
        renderDeepLinkBinding(index: index, parameter: parameter)
    }
    let arguments = item.parameters.enumerated().map { index, parameter in
        "\(parameter.emittedLabel): deepLinkValue\(index)"
    }.joined(separator: ", ")
    let constructor = arguments.isEmpty
        ? ".\(item.caseName)"
        : ".\(item.caseName)(\(arguments))"
    statements.append("return \(constructor)")

    return "InnoRouterDeepLink.DeepLinkMapping(\(swiftStringLiteral(item.pattern))) { parameters in\n"
        + indentEveryLine(statements.joined(separator: "\n"), by: 4)
        + "\n}"
}

private func renderDeepLinkBinding(
    index: Int,
    parameter: RouterDeepLinkParameter
) -> String {
    let name = "deepLinkValue\(index)"
    let key = swiftStringLiteral(parameter.label)
    if parameter.isOptional {
        return """
        let \(name): \(parameter.type)
        if parameters.firstValue(forName: \(key)) != nil {
            guard let parsedDeepLinkValue\(index) = parameters.firstValue(
                forName: \(key),
                as: \(parameter.wrappedType).self
            ) else {
                return nil
            }
            \(name) = parsedDeepLinkValue\(index)
        } else {
            \(name) = nil
        }
        """
    }
    return """
    guard let \(name) = parameters.firstValue(
        forName: \(key),
        as: \(parameter.wrappedType).self
    ) else {
        return nil
    }
    """
}

func swiftStringLiteral(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func indentEveryLine(_ value: String, by spaces: Int) -> String {
    let indentation = String(repeating: " ", count: spaces)
    return value
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { indentation + String($0) }
        .joined(separator: "\n")
}

func indentContinuationLines(_ value: String, by spaces: Int) -> String {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first else { return value }
    let indentation = String(repeating: " ", count: spaces)
    return ([String(first)] + lines.dropFirst().map { indentation + String($0) })
        .joined(separator: "\n")
}
