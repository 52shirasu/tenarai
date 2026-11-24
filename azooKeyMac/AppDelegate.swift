//
//  AppDelegate.swift
//  AppDelegate
//
//  Created by ensan on 2021/09/06.
//

import Cocoa
import Core
import InputMethodKit
import SwiftUI

// Necessary to launch this app
class NSManualApplication: NSApplication {
    let appDelegate = AppDelegate()

    override init() {
        super.init()
        self.delegate = appDelegate
    }

    required init?(coder: NSCoder) {
        // No need for implementation
        fatalError("init(coder:) has not been implemented")
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var server = IMKServer()
    weak var configWindow: NSWindow?
    weak var userDictionaryEditorWindow: NSWindow?
    var configWindowController: NSWindowController?
    var userDictionaryEditorWindowController: NSWindowController?
    private let converterServerClient = ConverterServerClient()
    private var systemDictionaryRefreshTimer: Timer?
    private var systemDictionaryRefreshInProgress = false
    private var systemDictionaryExportPending = false
    /// 前回見た流行語の一覧の stamp。週1回の更新プログラムが一覧を作り直したら変わる
    private var lastTrendWordsStamp: String?

    @MainActor private func refreshSystemDictionary() {
        guard !systemDictionaryRefreshInProgress else { return }
        systemDictionaryRefreshInProgress = true
        Task { @MainActor in
            defer { systemDictionaryRefreshInProgress = false }
            let entries = await Task.detached(priority: .utility) {
                try? SystemUserDictionaryHelper.fetchEntriesAutomatically()
            }.value
            // A failed read must not erase the last successfully imported dictionary.
            guard let entries else { return }
            var value = Config.SystemUserDictionary().value
            let unchanged = value.items.count == entries.count && zip(value.items, entries).allSatisfy {
                $0.word == $1.phrase && $0.reading == $1.shortcut
            }
            guard !unchanged || value.lastUpdate == nil || systemDictionaryExportPending else { return }
            value.items = entries.map { .init(word: $0.phrase, reading: $0.shortcut) }
            value.lastUpdate = .now
            Config.SystemUserDictionary().value = value
            systemDictionaryExportPending = true
            converterServerClient.synchronizeUserDictionary(forceExport: true) { [weak self] success in
                self?.systemDictionaryExportPending = !success
            }
        }
    }

    /// 流行語の一覧（または設定）が前回から変わっていたら、ヘルパーに同期を頼む。
    /// 書き出すかどうかはヘルパー側の `needsExport` が判断する。初回は値を覚えるだけ
    @MainActor private func synchronizeIfTrendWordsChanged() {
        let fileURL = TrendWordsStore.fileURL(applicationSupportDirectoryURL: AppGroup.applicationSupportDirectoryURL())
        let stamp = TrendWordsStore.stamp(for: fileURL, enabled: Config.TrendWords().value)
        defer { self.lastTrendWordsStamp = stamp }
        guard let lastTrendWordsStamp, lastTrendWordsStamp != stamp else {
            return
        }
        self.synchronizeUserDictionaryOnServer(forceExport: false)
    }

    private func exportInitialUserDictionaryIfNeeded() {
        Task { @MainActor in
            self.synchronizeUserDictionaryOnServer(forceExport: false)
        }
    }

    func exportUserDictionaryAndReloadConverter() {
        Task { @MainActor in
            self.synchronizeUserDictionaryOnServer(forceExport: true)
        }
    }

    @MainActor
    private func synchronizeUserDictionaryOnServer(forceExport: Bool) {
        self.converterServerClient.synchronizeUserDictionary(forceExport: forceExport) { success in
            if !success {
                print("Failed to synchronize user dictionary on ConverterServer")
            }
        }
    }

    private static func buildSwiftUIWindow(
        _ view: some View,
        contentRect: NSRect = NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .borderless],
        title: String = ""
    ) -> (window: NSWindow, windowController: NSWindowController) {
        // Create a new window
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // Set the window title
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        // Keep window with in a controller
        let windowController = NSWindowController(window: window)
        // Show the window
        window.level = .modalPanel
        window.makeKeyAndOrderFront(nil)
        return (window, windowController)
    }

    func openConfigWindow() {
        if let configWindow {
            // Show the window
            configWindow.level = .modalPanel
            configWindow.makeKeyAndOrderFront(nil)
        } else {
            // Create a new window
            (self.configWindow, self.configWindowController) = Self.buildSwiftUIWindow(ConfigWindow(), title: "設定")
        }
    }

    func openUserDictionaryEditorWindow() {
        if let userDictionaryEditorWindow {
            // Show the window
            userDictionaryEditorWindow.level = .modalPanel
            userDictionaryEditorWindow.makeKeyAndOrderFront(nil)
        } else {
            (self.userDictionaryEditorWindow, self.userDictionaryEditorWindowController) = Self.buildSwiftUIWindow(UserDictionaryEditorWindow(), title: "設定")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Insert code here to initialize your application
        self.server = IMKServer(name: Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
        NSLog("tried connection")

        // Keychainから設定値を非同期で読み込み
        Task {
            await Config.OpenAiApiKey.loadFromKeychain()
        }
        self.exportInitialUserDictionaryIfNeeded()
        self.refreshSystemDictionary()
        self.synchronizeIfTrendWordsChanged()
        self.systemDictionaryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSystemDictionary()
                self?.synchronizeIfTrendWordsChanged()
            }
        }

        // Check if mainMenu exists, or create it
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = NSMenu()
        }

        // Add an Edit menu
        let editMenu = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        NSApp.mainMenu?.addItem(editMenu)
        let editSubmenu = NSMenu(title: "Edit")
        editMenu.submenu = editSubmenu

        // Add standard Edit actions
        editSubmenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editSubmenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editSubmenu.addItem(NSMenuItem.separator())
        editSubmenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editSubmenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editSubmenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editSubmenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Insert code here to tear down your application
    }
}
