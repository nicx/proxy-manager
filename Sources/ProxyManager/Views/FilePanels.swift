import AppKit
import UniformTypeIdentifiers

/// Native open/save panels run app-modally. Unlike SwiftUI's `.fileImporter`/
/// `.fileExporter` (which attach a sheet to the MenuBarExtra window and make it
/// dismiss), these work reliably from a menu-bar popover. Call from the main
/// actor (e.g. a SwiftUI button action).
@MainActor
enum FilePanels {
    static func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Wählen"
        p.message = "Backup-Ordner wählen"
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    static func openJSON() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    static func saveJSON(suggestedName: String) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedName
        p.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }
}
