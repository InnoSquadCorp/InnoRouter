// MARK: - RouterDeepLinkExpansion.swift
// InnoRouterMacrosPlugin - @Router deep-link expansion orchestration
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterPatternSupport
import SwiftSyntax
import SwiftSyntaxMacros

enum RouterDeepLinkExpansion {
    case none
    case invalid
    case valid(RouterDeepLinkSpecification)
}

struct RouterDeepLinkSpecification {
    let schemes: [String]
    let hosts: [String]
    let items: [RouterDeepLinkItem]
    let directlyConformsToDeepLinkRoute: Bool
    let hasUnmappedCases: Bool
    let generatesInspectorCatalog: Bool
}

struct RouterDeepLinkItem {
    let caseName: String
    let pattern: String
    let parameters: [RouterDeepLinkParameter]
    let attribute: AttributeSyntax
}

struct RouterDeepLinkParameter {
    let label: String
    let emittedLabel: String
    let type: String
    let wrappedType: String
    let isOptional: Bool
}

func analyzeRouterDeepLinks(
    routerAttribute: AttributeSyntax,
    in enumDecl: EnumDeclSyntax,
    featureCaseCount: Int = 0,
    context: some MacroExpansionContext
) -> RouterDeepLinkExpansion {
    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let conditionalCases = enumDecl.memberBlock.members.flatMap { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            return [EnumCaseDeclSyntax]()
        }
        return deepLinkCasesInsideConditional(conditional)
    }
    let markedDirectCases = directCases.filter { !deepLinkAttributes(on: $0).isEmpty }
    let conditionallyAttributedDirectCases = directCases.filter {
        conditionalDeepLinkAttribute(on: $0) != nil
    }
    let markedConditionalCases = conditionalCases.filter { containsDeepLinkAttribute(on: $0) }

    let originResult = parseDeepLinkOrigin(from: routerAttribute)
    switch originResult {
    case .failure(let reason):
        diagnoseDeepLink(.invalidRouterArguments(reason: reason), at: routerAttribute, context: context)
        return .invalid
    case .success(let origin):
        if let conditionalCase = markedConditionalCases.first {
            diagnoseDeepLink(.conditionalCase, at: conditionalCase, context: context)
            return .invalid
        }
        if let conditionalAttribute = conditionallyAttributedDirectCases
            .lazy
            .compactMap(conditionalDeepLinkAttribute(on:))
            .first {
            diagnoseDeepLink(.conditionalCase, at: conditionalAttribute, context: context)
            return .invalid
        }
        guard !markedDirectCases.isEmpty || !markedConditionalCases.isEmpty else {
            if origin.hasValues && featureCaseCount > 0 {
                return .valid(
                    RouterDeepLinkSpecification(
                        schemes: origin.schemes,
                        hosts: origin.hosts,
                        items: [],
                        directlyConformsToDeepLinkRoute: directlyConforms(
                            enumDecl,
                            to: "DeepLinkRoute"
                        ),
                        hasUnmappedCases: directCases.flatMap(\.elements).count != featureCaseCount
                            || !conditionalCases.isEmpty,
                        generatesInspectorCatalog: origin.generatesInspectorCatalog
                    )
                )
            }
            if origin.hasValues {
                diagnoseUnusedDeepLinkAllowlist(routerAttribute, in: enumDecl, context: context)
            }
            return .none
        }

        guard origin.schemes.isEmpty == false, origin.hosts.isEmpty == false else {
            diagnoseDeepLink(.missingAllowlist, at: routerAttribute, context: context)
            return .invalid
        }
        var items: [RouterDeepLinkItem] = []
        for caseDecl in markedDirectCases {
            guard let item = analyzeDeepLinkCase(caseDecl, context: context) else {
                return .invalid
            }
            items.append(item)
        }

        let patterns = items.map { RoutePattern($0.pattern) }
        let orderedItems = RoutePattern
            .specificityOrderedIndices(for: patterns)
            .map { items[$0] }

        guard validateDeepLinkReachability(orderedItems, context: context) else {
            return .invalid
        }
        if let conflictingResolver = conflictingDeepLinkResolver(in: enumDecl) {
            diagnoseDeepLink(.conflictingResolver, at: conflictingResolver, context: context)
            return .invalid
        }
        if let conflictingRenderer = conflictingDeepLinkURLRenderer(in: enumDecl) {
            diagnoseDeepLink(.conflictingURLRenderer, at: conflictingRenderer, context: context)
            return .invalid
        }

        let directlyConforms = directlyConforms(enumDecl, to: "DeepLinkRoute")
        if directlyConforms, let inheritanceClause = enumDecl.inheritanceClause {
            diagnoseDeepLink(
                .redundantConformance,
                at: inheritanceClause,
                context: context,
                fixIts: [
                    removeConformanceFixIt(
                        named: "DeepLinkRoute",
                        from: inheritanceClause,
                        in: enumDecl
                    ),
                ].compactMap { $0 }
            )
        }

        return .valid(
            RouterDeepLinkSpecification(
                schemes: origin.schemes,
                hosts: origin.hosts,
                items: orderedItems,
                directlyConformsToDeepLinkRoute: directlyConforms,
                hasUnmappedCases: directCases.flatMap(\.elements).count
                    != items.count + featureCaseCount
                    || !conditionalCases.isEmpty,
                generatesInspectorCatalog: origin.generatesInspectorCatalog
            )
        )
    }
}

/// Warns that deep-link allowlists have no effect on a router with no
/// `@DeepLink` case, offering to drop just those arguments.
private func diagnoseUnusedDeepLinkAllowlist(
    _ routerAttribute: AttributeSyntax,
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) {
    diagnoseDeepLink(
        .unusedAllowlist,
        at: routerAttribute,
        context: context,
        fixIts: [
            removeAttributeArgumentsFixIt(
                routerAttribute,
                labels: ["deepLinkSchemes", "deepLinkHosts"],
                in: enumDecl
            ),
        ].compactMap { $0 }
    )
}
