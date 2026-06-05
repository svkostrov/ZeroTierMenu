import Foundation
import Darwin

struct NetworkScannerService {
    func scan(subnetCIDR: String, excluding localIPv4: String?, networkID: String, networkName: String) async -> [NetworkHost] {
        guard let subnet = IPv4Subnet(cidr: subnetCIDR) else {
            return []
        }

        let candidates = subnet.hostAddresses.filter { $0 != localIPv4 }
        let limiter = AsyncLimiter(limit: 24)

        return await withTaskGroup(of: NetworkHost?.self, returning: [NetworkHost].self) { group in
            for ip in candidates {
                group.addTask {
                    await limiter.acquire()
                    let result = await scanHost(ip, networkID: networkID, networkName: networkName)
                    await limiter.release()
                    return result
                }
            }

            var hosts: [NetworkHost] = []
            for await host in group {
                if let host {
                    hosts.append(host)
                }
            }
            return hosts
        }
    }

    func probe(hostIPs: [String]) async -> [NetworkHost] {
        let uniqueIPs = Array(Set(hostIPs)).sorted()
        let limiter = AsyncLimiter(limit: 12)

        return await withTaskGroup(of: NetworkHost.self, returning: [NetworkHost].self) { group in
            for ip in uniqueIPs {
                group.addTask {
                    await limiter.acquire()
                    let result = await probeHost(ip)
                    await limiter.release()
                    return result
                }
            }

            var hosts: [NetworkHost] = []
            for await host in group {
                hosts.append(host)
            }
            return hosts
        }
    }

    private func scanHost(_ ip: String, networkID: String, networkName: String) async -> NetworkHost? {
        let isReachable = await ping(ip)
        guard isReachable else { return nil }

        let resolvedName = resolveHostName(ip)
        let hostName = resolvedName ?? ip
        return NetworkHost(
            id: "\(networkID)|\(ip)",
            networkID: networkID,
            networkName: networkName,
            displayName: hostName,
            resolvedName: resolvedName,
            ipv4Addresses: [ip],
            isOnline: true,
            isManual: false
        )
    }

    private func probeHost(_ ip: String) async -> NetworkHost {
        let isReachable = await ping(ip)
        let resolvedName = resolveHostName(ip)
        let hostName = resolvedName ?? ip
        return NetworkHost(
            id: ip,
            networkID: nil,
            networkName: nil,
            displayName: hostName,
            resolvedName: resolvedName,
            ipv4Addresses: [ip],
            isOnline: isReachable,
            isManual: true
        )
    }

    private func ping(_ ip: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/ping")
                process.arguments = ["-c", "1", "-t", "1", "-W", "800", ip]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func resolveHostName(_ ip: String) -> String? {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)

        let conversion = ip.withCString { inet_pton(AF_INET, $0, &socketAddress.sin_addr) }
        guard conversion == 1 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }

        guard result == 0 else { return nil }
        let rawHostName = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let hostName = rawHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? nil : hostName
    }
}

private struct IPv4Subnet {
    let hostAddresses: [String]

    init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let base = IPv4Address(String(parts[0])),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix) else {
            return nil
        }

        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        let network = base.rawValue & mask
        let broadcast = network | ~mask

        var addresses: [String] = []
        if prefix >= 31 {
            for value in network...broadcast {
                addresses.append(IPv4Address(rawValue: value).stringValue)
            }
        } else {
            let start = network + 1
            let end = broadcast - 1
            if start <= end {
                for value in start...end {
                    addresses.append(IPv4Address(rawValue: value).stringValue)
                }
            }
        }

        self.hostAddresses = addresses
    }
}

private struct IPv4Address {
    let rawValue: UInt32

    init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        self.rawValue = value
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var stringValue: String {
        [
            String((rawValue >> 24) & 0xFF),
            String((rawValue >> 16) & 0xFF),
            String((rawValue >> 8) & 0xFF),
            String(rawValue & 0xFF)
        ].joined(separator: ".")
    }
}

actor AsyncLimiter {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        inFlight += 1
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
            return
        }
        inFlight -= 1
    }
}
