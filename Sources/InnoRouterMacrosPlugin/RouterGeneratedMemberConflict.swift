import SwiftSyntax

/// A manual declaration that a generated member cannot coexist with.
struct RouterGeneratedMemberConflict {
    let name: String
    let declaration: DeclSyntax
}

/// Finds the first manual declaration that really collides with a generated
/// member.
///
/// Swift decides collisions by declaration kind, by static versus instance, and
/// by parameter list, so this analyzer does the same for every helper. Two
/// consequences are shared by all of them:
///
/// - Generated helpers are `static`, so an instance property of the same name
///   is a legal declaration that coexists with them and must be accepted.
/// - Members inside `#if` are left to the compiler. A macro cannot evaluate
///   build conditions, and rejecting an inactive branch fails code whose
///   generated member was never built for that configuration. A real collision
///   in an active branch is still reported, by the compiler.
///
/// Pass only the names a helper actually generates: `typeMembers` for nested
/// types, `staticMembers` for type-level properties, and `parameterlessCases`
/// for enum cases that would shadow a generated static member.
func firstRouterGeneratedMemberConflict(
    in members: MemberBlockItemListSyntax,
    typeMembers: Set<String> = [],
    staticMembers: Set<String> = [],
    parameterlessCases: Set<String> = []
) -> RouterGeneratedMemberConflict? {
    for member in members {
        let declaration = member.decl
        if !typeMembers.isEmpty,
           let name = nestedTypeName(of: declaration),
           typeMembers.contains(name) {
            return .init(name: name, declaration: declaration)
        }

        if !staticMembers.isEmpty,
           let variable = declaration.as(VariableDeclSyntax.self),
           isTypeLevel(variable) {
            for binding in variable.bindings {
                guard let identifier = binding.pattern
                    .as(IdentifierPatternSyntax.self)?.identifier.text,
                    staticMembers.contains(identifier) else {
                    continue
                }
                return .init(name: identifier, declaration: declaration)
            }
        }

        if !parameterlessCases.isEmpty,
           let enumCase = declaration.as(EnumCaseDeclSyntax.self) {
            for element in enumCase.elements
            where element.parameterClause == nil
                && parameterlessCases.contains(element.name.text) {
                return .init(name: element.name.text, declaration: declaration)
            }
        }
    }
    return nil
}

private func isTypeLevel(_ variable: VariableDeclSyntax) -> Bool {
    variable.modifiers.contains { modifier in
        modifier.name.tokenKind == .keyword(.static)
            || modifier.name.tokenKind == .keyword(.class)
    }
}

private func nestedTypeName(of declaration: DeclSyntax) -> String? {
    if let declaration = declaration.as(EnumDeclSyntax.self) {
        return declaration.name.text
    }
    if let declaration = declaration.as(StructDeclSyntax.self) {
        return declaration.name.text
    }
    if let declaration = declaration.as(ClassDeclSyntax.self) {
        return declaration.name.text
    }
    if let declaration = declaration.as(TypeAliasDeclSyntax.self) {
        return declaration.name.text
    }
    return nil
}
