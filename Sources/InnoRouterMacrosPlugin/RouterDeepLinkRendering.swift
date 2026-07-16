import Foundation

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
