// REEngine.swift - AI-powered Reverse Engineering toolkit
// Artcraft-style: extract binary intelligence, AI analyzes, generates replication
// Part of Deck iOS app

import Foundation

/// AI-powered reverse engineering engine
/// Uses local LLM to understand and replicate software behavior from binary analysis
final class REEngine: @unchecked Sendable {
    static let shared = REEngine()
    private init() {}

    // MARK: - Deep String Analysis with AI categorization

    /// Extract strings and categorize by semantic type using pattern matching
    /// Returns categorized strings for AI analysis
    func deepStrings(path: String, minLength: Int = 4) -> [String: [String]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }

        var categories: [String: [String]] = [
            "urls": [], "apis": [], "keys": [], "ui": [],
            "errors": [], "paths": [], "other": []
        ]

        // Extract printable strings
        var current = ""
        var allStrings: [String] = []

        for byte in data {
            if byte >= 32 && byte < 127 {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= minLength {
                    allStrings.append(current)
                }
                current = ""
            }
        }
        if current.count >= minLength { allStrings.append(current) }

        // Categorize
        for s in allStrings {
            let lower = s.lowercased()
            if s.hasPrefix("http://") || s.hasPrefix("https://") {
                categories["urls"]?.append(s)
            } else if lower.contains("api") && (s.contains("/") || s.contains(".")) {
                categories["apis"]?.append(s)
            } else if lower.contains("key") || lower.contains("secret") || lower.contains("token") {
                categories["keys"]?.append(s)
            } else if lower.contains("button") || lower.contains("label") || lower.contains("view") {
                categories["ui"]?.append(s)
            } else if lower.contains("error") || lower.contains("fail") || lower.contains("exception") {
                categories["errors"]?.append(s)
            } else if s.hasPrefix("/") && s.contains("/") {
                categories["paths"]?.append(s)
            } else {
                categories["other"]?.append(s)
            }
        }

        // Cap each category
        for k in categories.keys {
            categories[k] = Array(categories[k]!.prefix(50))
        }

        return categories
    }

    // MARK: - Objective-C Runtime Introspection

    /// Dump Objective-C classes and methods from a loaded binary
    /// Uses runtime introspection (only works for current process)
    func objcDump() -> String {
        var result = "Objective-C Runtime Classes:\n"
        var count: UInt32 = 0

        guard let classes = objc_copyClassList(&count) else {
            return "Failed to get class list"
        }
        defer { free(classes) }

        let maxClasses = min(Int(count), 200)
        for i in 0..<maxClasses {
            let cls: AnyClass = classes[i]
            let name = String(cString: class_getName(cls))

            // Only show app-specific classes (not system)
            if name.hasPrefix("Deck") || name.contains("RE") {
                result += "\n\(name):\n"

                var methodCount: UInt32 = 0
                if let methods = class_copyMethodList(cls, &methodCount) {
                    let maxMethods = min(Int(methodCount), 20)
                    for j in 0..<maxMethods {
                        let method = methods[j]
                        let selName = String(cString: sel_getName(method_getName(method)))
                        result += "  - \(selName)\n"
                    }
                    free(methods)
                }
            }
        }

        return result
    }

    // MARK: - Behavior Inference

    /// Analyze binary metadata to infer behavior patterns
    /// Returns structured behavior profile
    func behaviorProfile(path: String) -> String {
        var profile = "=== Behavior Profile ===\n"
        profile += "Target: \(path)\n\n"

        // Get basic info
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return "Cannot access file"
        }
        profile += "Size: \(size.intValue) bytes\n"

        // Categorized strings
        let strings = deepStrings(path: path)

        profile += "\n--- Network Indicators ---\n"
        for url in (strings["urls"] ?? []).prefix(10) {
            profile += "  URL: \(url)\n"
        }
        for api in (strings["apis"] ?? []).prefix(10) {
            profile += "  API: \(api)\n"
        }

        profile += "\n--- UI Elements ---\n"
        for ui in (strings["ui"] ?? []).prefix(10) {
            profile += "  UI: \(ui)\n"
        }

        profile += "\n--- File System ---\n"
        for p in (strings["paths"] ?? []).prefix(10) {
            profile += "  Path: \(p)\n"
        }

        profile += "\n--- Error Handling ---\n"
        for e in (strings["errors"] ?? []).prefix(10) {
            profile += "  Error: \(e)\n"
        }

        // Inference summary
        profile += "\n--- Inferred Capabilities ---\n"
        if !(strings["urls"] ?? []).isEmpty {
            profile += "  ✓ Network communication\n"
        }
        if !(strings["ui"] ?? []).isEmpty {
            profile += "  ✓ User interface\n"
        }
        if !(strings["paths"] ?? []).isEmpty {
            profile += "  ✓ File system access\n"
        }

        return profile
    }

    // MARK: - AI-Powered Analysis Prompt Generation

    /// Generate a prompt for the local LLM to analyze binary behavior
    /// This is the Artcraft-style AI reverse engineering step
    func aiAnalysisPrompt(path: String) -> String {
        let profile = behaviorProfile(path: path)
        let strings = deepStrings(path: path)

        var prompt = """
        You are a reverse engineering expert. Analyze this iOS binary and describe its behavior.

        \(profile)

        Key strings found:
        """

        // Add sample strings from each category
        for (category, items) in strings {
            if !items.isEmpty {
                prompt += "\n\(category.uppercased()) (sample):\n"
                for s in items.prefix(5) {
                    prompt += "  - \(s)\n"
                }
            }
        }

        prompt += """

        Provide:
        1. Primary function/purpose (one sentence)
        2. Key capabilities (bullet list)
        3. Network behavior (if any)
        4. Data storage approach
        5. Potential replication strategy (how to rebuild this functionality)

        Be concise and technical.
        """

        return prompt
    }

    // MARK: - Replication Scaffold Generation

    /// Generate Swift code scaffold to replicate observed behavior
    /// Takes AI analysis output and generates starter code
    func replicationScaffold(analysis: String, appName: String) -> String {
        return """
        // \(appName) - Replication Scaffold
        // Generated by Deck RE Engine (Artcraft-style AI reverse engineering)
        // Based on AI analysis of target binary behavior

        import Foundation
        import UIKit

        /// Replicated from: \(appName)
        /// Analysis summary:
        /// \(analysis.prefix(500))

        final class \(appName)Replica: @unchecked Sendable {

            // MARK: - Core Functionality
            // TODO: Implement based on AI analysis above

            func initialize() {
                // Setup based on observed behavior
            }

            // MARK: - Network Layer (if applicable)
            // TODO: Replicate API endpoints discovered in strings

            // MARK: - Data Layer
            // TODO: Replicate storage patterns

            // MARK: - UI Layer
            // TODO: Replicate interface elements
        }

        // Usage:
        // let replica = \(appName)Replica()
        // replica.initialize()
        """
    }
}

// MARK: - DeckTools Integration

extension REEngine {
    /// Main entry point for DeckTools
    func analyze(path: String) -> String {
        return behaviorProfile(path: path)
    }

    func aiPrompt(path: String) -> String {
        return aiAnalysisPrompt(path: path)
    }
}
