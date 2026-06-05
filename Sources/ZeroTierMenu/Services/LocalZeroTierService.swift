import Foundation

struct LocalZeroTierService {
    func loadNetworkContexts() async -> [LocalNetworkContext] {
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
                return []
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let networks = try JSONDecoder().decode([LocalNetwork].self, from: data)
            return networks
                .filter { $0.status == "OK" && ($0.id != nil || $0.nwid != nil) }
                .compactMap { network in
                    let networkID = network.id ?? network.nwid ?? ""
                    guard !networkID.isEmpty else { return nil }

                    let ipv4 = network.assignedAddresses?
                        .map { $0.split(separator: "/").first.map(String.init) ?? $0 }
                        .first(where: { $0.contains(".") })

                    let subnet = network.routes?
                        .compactMap(\.target)
                        .first(where: { $0.contains(".") && $0.contains("/") })

                    return LocalNetworkContext(
                        networkID: networkID,
                        name: network.name ?? "",
                        ipv4: ipv4,
                        subnet: subnet
                    )
                }
        } catch {
            return []
        }
    }
}

struct LocalNetworkContext: Identifiable, Equatable {
    var id: String { networkID }
    let networkID: String
    let name: String
    let ipv4: String?
    let subnet: String?
}

private struct LocalNetwork: Decodable {
    let id: String?
    let nwid: String?
    let name: String?
    let status: String?
    let assignedAddresses: [String]?
    let routes: [LocalRoute]?
}

private struct LocalRoute: Decodable {
    let target: String?
}
