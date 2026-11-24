//
//  StringConfigItem.swift
//  azooKeyMac
//
//  Created by miwa on 2024/04/27.
//

import Foundation

protocol StringConfigItem: ConfigItem<String> {}

extension StringConfigItem {
    public var value: String {
        get {
            Config.string(forKey: Self.key) ?? ""
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiProfile: StringConfigItem {
        public init() {}

        public static let key: String = "local.tenarai.inputmethod.tenarai.preference.ZenzaiProfile"
    }
}

extension Config {
    /// OpenAIモデル名
    public struct OpenAiModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = "gpt-4o-mini"
        public static let key: String = "local.tenarai.inputmethod.tenarai.preference.OpenAiModelName"
    }

    /// OpenAI API エンドポイント
    public struct OpenAiApiEndpoint: StringConfigItem {
        public init() {}

        public static let `default` = "https://api.openai.com/v1/chat/completions"
        public static let key: String = "local.tenarai.inputmethod.tenarai.preference.OpenAiApiEndpoint"

        public var value: String {
            get {
                let stored = Config.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                Config.set(newValue, forKey: Self.key)
            }
        }
    }

    /// プロンプト履歴（JSON形式で保存）
    public struct PromptHistory: StringConfigItem {
        public static let key: String = "local.tenarai.inputmethod.tenarai.preference.PromptHistory"
    }
}

extension Config {
    /// Apps whose input is never learned (conversion memory, tendencies, personal model).
    /// Terminals see commands and pasted secrets; password managers see passwords.
    public struct LearningExcludedApps: StringConfigItem {
        public init() {}

        public static let `default` = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
            "com.apple.keychainaccess", "com.apple.Passwords"
        ].joined(separator: ", ")
        public static let key: String = "local.tenarai.inputmethod.tenarai.preference.LearningExcludedApps"

        /// The stored list, or the default when the user never edited it.
        public var effectiveValue: String {
            Config.string(forKey: Self.key) ?? Self.default
        }

        public static func identifiers(in value: String) -> Set<String> {
            Set(value.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init))
        }

        public func excludes(_ appIdentifier: String?) -> Bool {
            guard let appIdentifier, !appIdentifier.isEmpty else { return false }
            return Self.identifiers(in: effectiveValue).contains(appIdentifier)
        }
    }
}
