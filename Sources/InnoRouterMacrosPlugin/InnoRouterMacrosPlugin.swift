// MARK: - InnoRouterMacrosPlugin.swift
// InnoRouter Macros - Compiler Plugin Entry Point
// Copyright © 2025 Inno Squad. All rights reserved.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct InnoRouterMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RouterMacro.self,
        RoutableMacro.self,
        CasePathableMacro.self,
    ]
}
