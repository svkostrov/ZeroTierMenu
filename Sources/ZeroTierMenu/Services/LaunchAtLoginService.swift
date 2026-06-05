import Foundation

@MainActor
struct LaunchAtLoginService {
    private let fileManager = FileManager.default
    private let label = "com.rokot.ZeroTierMenu.launcher"

    func isEnabled() -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writeLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
    }

    private var plistURL: URL {
        let launchAgentsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private func writeLaunchAgent() throws {
        let appPath = "/Applications/ZeroTierMenu.app"
        let executablePath = "\(appPath)/Contents/MacOS/ZeroTierMenu"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        let launchAgentsDirectory = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func removeLaunchAgent() throws {
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        try fileManager.removeItem(at: plistURL)
    }
}
