// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

/// Known tokens emitted by `swift sdk list`.
enum SwiftSDKToken: String {
    case android
    case wasm
    case wasi
    case wasip1
}

/// Capabilities that Skip can request from an installed Swift SDK.
enum SwiftSDKCapability {
    case webAssembly
}

/// A normalized SDK kind, avoiding feature detection through raw substring checks.
enum SwiftSDKKind: Equatable {
    case android
    case webAssembly
    case other

    init(identifier: String) {
        var detectedAndroid = false
        for token in identifier.split(whereSeparator: { character in
            switch character {
            case "-", "_", ".":
                return true
            default:
                return false
            }
        }) {
            switch SwiftSDKToken(rawValue: token.lowercased()) {
            case .android:
                detectedAndroid = true
            case .wasm, .wasi, .wasip1:
                self = .webAssembly
                return
            case nil:
                break
            }
        }
        self = detectedAndroid ? .android : .other
    }
}

struct SwiftSDKInventory {
    private let kinds: [SwiftSDKKind]

    init(output: String) {
        kinds = output
            .split(whereSeparator: \.isNewline)
            .map { SwiftSDKKind(identifier: String($0)) }
    }

    func supports(_ capability: SwiftSDKCapability) -> Bool {
        switch capability {
        case .webAssembly:
            for kind in kinds {
                if kind == .webAssembly {
                    return true
                }
            }
            return false
        }
    }
}
