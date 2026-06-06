import Foundation

struct NetworkScannerService {

    func reachability(hostIPs: [String]) async -> [String: Bool] {
        let uniqueIPs = Array(Set(hostIPs)).sorted()
        let limiter = AsyncLimiter(limit: 12)

        return await withTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for ip in uniqueIPs {
                group.addTask {
                    await limiter.acquire()
                    let result = await ping(ip)
                    await limiter.release()
                    return (ip, result)
                }
            }

            var statuses: [String: Bool] = [:]
            for await (ip, isReachable) in group {
                statuses[ip] = isReachable
            }
            return statuses
        }
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
