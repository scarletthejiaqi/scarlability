import Foundation

enum Platform {
    /// Running as the Mac app (Mac Catalyst): the mouse and trackpad draw, there's no camera or
    /// document scanner, and no Apple Pencil.
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp
}
