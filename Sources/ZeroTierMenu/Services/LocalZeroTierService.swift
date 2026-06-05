import Foundation

struct LocalZeroTierService {
    func loadNetworkContext(networkID: String) async -> LocalNetworkContext? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/zerotier-cli")
        process.arguments = ["listnetworks", "-j"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let networks = try JSONDecoder().decode([LocalNetwork].self, from: data)
            guard let match = networks.first(where: { $0.id == networkID || $0.nwid == networkID }) else {
                return nil
            }

            let ipv4 = match.assignedAddresses?
                .map { $0.split(separator: "/").first.map(String.init) ?? $0 }
                .first(where: { $0.contains(".") })

            let subnet = match.routes?
                .compactMap(\.target)
                .first(where: { $0.contains(".") && $0.contains("/") })

            return LocalNetworkContext(name: match.name ?? "", ipv4: ipv4, subnet: subnet)
        } catch {
            return nil
        }
    }
}

struct LocalNetworkContext {
    let name: String
    let ipv4: String?
    let subnet: String?
}

private struct LocalNetwork: Decodable {
    let id: String?
    let nwid: String?
    let name: String?
    let assignedAddresses: [String]?
    let routes: [LocalRoute]?
}

private struct LocalRoute: Decodable {
    let target: String?
}
