import Foundation
import Darwin
import dnssd
import PersonaStackCore

@MainActor
protocol DesktopLocalNetworkRegistering: AnyObject {
    /// Reports completion, not merely successful submission to mDNSResponder.
    func start(reply: @escaping @MainActor (Int32, Bool) -> Void) -> Int32
    func cancel()
}

/// Setup-only registration. No socket listens for or accepts inbound connections.
/// TN3179 documents Bonjour registration as requiring local-network access:
/// https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
/// DNSServiceRegisterReply documents NoError + Add as successful registration:
/// https://developer.apple.com/documentation/dnssd/dnsserviceregisterreply
@MainActor
enum DesktopLocalNetworkPermission {
    static let serviceType = "_ps-setup._tcp"

    static func request(timeout: Duration = .seconds(12)) async -> DesktopPermissionObservation {
        if #unavailable(macOS 15) {
            return .init(.notNeeded, detail: "This macOS version has no Local Network privacy approval.")
        }
        return await request(registration: BonjourRegistration(), eligibleInterface: hasEligibleInterface(), timeout: timeout)
    }

    static func request(registration: any DesktopLocalNetworkRegistering, eligibleInterface: Bool = true,
                        timeout: Duration = .seconds(12)) async -> DesktopPermissionObservation {
        guard eligibleInterface else {
            return .init(.verificationRequired, detail: "Connect this Mac to Wi-Fi or Ethernet, then retry Local Network setup. No eligible network interface is active.")
        }
        let cancellation = Cancellation()
        let probe = Probe(registration: registration, cancellation: cancellation)
        return await withTaskCancellationHandler {
            await probe.run(timeout: timeout)
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in probe.finish(.init(.verificationRequired, detail: "Local Network setup was cancelled.")) }
        }
    }

    private static func hasEligibleInterface() -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return false }
        defer { freeifaddrs(first) }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        return sequence(first: first, next: { $0.pointee.ifa_next }).contains { item in
            let value = item.pointee
            guard value.ifa_flags & required == required,
                  value.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = value.ifa_addr else { return false }
            return address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    @MainActor private final class Probe {
        let registration: any DesktopLocalNetworkRegistering
        let cancellation: Cancellation
        var continuation: CheckedContinuation<DesktopPermissionObservation, Never>?
        var deadline: Task<Void, Never>?
        var finished = false
        init(registration: any DesktopLocalNetworkRegistering, cancellation: Cancellation) {
            self.registration = registration
            self.cancellation = cancellation
        }

        func run(timeout: Duration) async -> DesktopPermissionObservation {
            guard !Task.isCancelled, !cancellation.isCancelled, !finished else {
                return .init(.verificationRequired, detail: "Local Network setup was cancelled.")
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                let error = registration.start { [weak self] error, added in
                    self?.received(error: error, added: added)
                }
                if error != kDNSServiceErr_NoError { received(error: error, added: false) }
                guard !finished else { return }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(.init(.verificationRequired, detail: "Local Network approval could not be verified. Check the network connection and Local Network settings, then retry."))
                }
            }
        }

        func received(error: Int32, added: Bool) {
            guard !cancellation.isCancelled else {
                finish(.init(.verificationRequired, detail: "Local Network setup was cancelled."))
                return
            }
            if error == kDNSServiceErr_PolicyDenied {
                finish(.init(.denied, detail: "macOS denied Local Network registration. Enable PersonaStack in Privacy & Security → Local Network, then retry."))
            } else if error != kDNSServiceErr_NoError {
                finish(.init(.verificationRequired, detail: "Local-network registration failed. Check the network connection and retry. This does not establish whether permission is denied."))
            } else if added {
                finish(.init(.ready, detail: "Local-network setup registration succeeded. The temporary registration was removed. No device content was read.", verified: true))
            }
        }

        func finish(_ observation: DesktopPermissionObservation) {
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            registration.cancel()
            let pending = continuation
            continuation = nil
            pending?.resume(returning: observation)
        }
    }

    @MainActor private final class BonjourRegistration: DesktopLocalNetworkRegistering {
        private var reference: DNSServiceRef?
        private var reply: (@MainActor (Int32, Bool) -> Void)?

        func start(reply: @escaping @MainActor (Int32, Bool) -> Void) -> Int32 {
            self.reply = reply
            // A fresh content-free instance name avoids publishing an account or device name.
            // This advertises the discard port only. It never creates a TCP listener.
            let name = "ps-setup-" + UUID().uuidString.lowercased()
            let error = DNSServiceRegister(&reference, DNSServiceFlags(kDNSServiceFlagsNoAutoRename), 0,
                name, serviceType, "local.", nil, UInt16(9).bigEndian, 0, nil,
                { _, flags, error, _, _, _, context in
                    guard let context else { return }
                    // DNSServiceSetDispatchQueue below confines callbacks and teardown to main.
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<BonjourRegistration>.fromOpaque(context).takeUnretainedValue()
                        owner.reply?(error, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0)
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError, let reference else { return error }
            return DNSServiceSetDispatchQueue(reference, .main)
        }

        func cancel() {
            reply = nil
            if let reference {
                DNSServiceRefDeallocate(reference)
                self.reference = nil
            }
        }
    }
}
