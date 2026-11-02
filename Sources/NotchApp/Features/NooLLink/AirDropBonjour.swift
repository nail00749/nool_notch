import Darwin
import Foundation
import dnssd

/// Gives the relay its own DNS identity. Reusing the Mac's SRV target can make
/// Finder discard the relay as the local sharingd instance.
final class AirDropBonjour: @unchecked Sendable {
    private var hostConnection: DNSServiceRef?
    private var service: DNSServiceRef?
    private var callbackID: UInt?
    private var hostReady = false
    private var serviceReady = false
    private var reportedReady = false
    private var completion: (@Sendable (Bool) -> Void)?
    private var watchdog: DispatchWorkItem?
    private static let callbacks = CallbackRegistry()

    func start(id: String, port: UInt16, queue: DispatchQueue, completion: @escaping @Sendable (Bool) -> Void) throws {
        let index = if_nametoindex("awdl0")
        guard index != 0, let address = Self.awdlAddress() else { throw NooLLinkError.unavailable }
        let hostname = "nool-" + id + ".local."
        var hostRef: DNSServiceRef?
        guard DNSServiceCreateConnection(&hostRef) == kDNSServiceErr_NoError, let hostRef else { throw NooLLinkError.unavailable }
        hostConnection = hostRef
        self.completion = completion
        let callbackID = Self.callbacks.insert(self)
        self.callbackID = callbackID
        let context = UnsafeMutableRawPointer(bitPattern: callbackID)
        guard DNSServiceSetDispatchQueue(hostRef, queue) == kDNSServiceErr_NoError else { stop(); throw NooLLinkError.unavailable }
        var record: DNSRecordRef?
        let registration = address.withUnsafeBytes { raw in
            DNSServiceRegisterRecord(hostRef, &record, DNSServiceFlags(kDNSServiceFlagsUnique), index,
                                     hostname, UInt16(kDNSServiceType_AAAA), UInt16(kDNSServiceClass_IN),
                                     UInt16(address.count), raw.baseAddress, 120, { _, _, _, error, context in
                                         AirDropBonjour.report(context, host: true, error: error)
                                     }, context)
        }
        guard registration == kDNSServiceErr_NoError else { stop(); throw NooLLinkError.unavailable }
        let txt = Data([9]) + Data("flags=136".utf8)
        var serviceRef: DNSServiceRef?
        let status = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&serviceRef, DNSServiceFlags(kDNSServiceFlagsIncludeP2P), index, id,
                               "_airdrop._tcp", "local.", hostname, port.bigEndian, UInt16(txt.count), raw.baseAddress,
                               { _, _, error, _, _, _, context in AirDropBonjour.report(context, host: false, error: error) }, context)
        }
        guard status == kDNSServiceErr_NoError, let serviceRef else { stop(); throw NooLLinkError.unavailable }
        service = serviceRef
        guard DNSServiceSetDispatchQueue(serviceRef, queue) == kDNSServiceErr_NoError else { stop(); throw NooLLinkError.unavailable }
        let watchdog = DispatchWorkItem { [weak self] in self?.registered(host: false, error: DNSServiceErrorType(kDNSServiceErr_Timeout)) }
        self.watchdog = watchdog
        queue.asyncAfter(deadline: .now() + 5, execute: watchdog)
    }

    func stop() {
        watchdog?.cancel(); watchdog = nil
        if let callbackID { Self.callbacks.remove(callbackID); self.callbackID = nil }
        completion = nil
        if let service { DNSServiceRefDeallocate(service); self.service = nil }
        if let hostConnection { DNSServiceRefDeallocate(hostConnection); self.hostConnection = nil }
    }

    private static func report(_ context: UnsafeMutableRawPointer?, host: Bool, error: DNSServiceErrorType) {
        guard let context, let receiver = callbacks.value(UInt(bitPattern: context)) else { return }
        receiver.registered(host: host, error: error)
    }

    private func registered(host: Bool, error: DNSServiceErrorType) {
        guard let completion else { return }
        if error != kDNSServiceErr_NoError {
            stop(); completion(false); return
        }
        if host { hostReady = true } else { serviceReady = true }
        if hostReady && serviceReady && !reportedReady {
            reportedReady = true; watchdog?.cancel(); watchdog = nil; completion(true)
        }
    }

    /// Integer callback handles avoid dereferencing released Swift instances if a
    /// DNS-SD callback was already queued when the registration was withdrawn.
    private final class CallbackRegistry: @unchecked Sendable {
        private final class WeakBox { weak var value: AirDropBonjour?; init(_ value: AirDropBonjour) { self.value = value } }
        private let lock = NSLock()
        private var counter: UInt = 1
        private var entries: [UInt: WeakBox] = [:]
        func insert(_ value: AirDropBonjour) -> UInt {
            lock.lock(); defer { lock.unlock() }
            counter &+= 1; entries[counter] = WeakBox(value); return counter
        }
        func value(_ id: UInt) -> AirDropBonjour? { lock.lock(); defer { lock.unlock() }; return entries[id]?.value }
        func remove(_ id: UInt) { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: id) }
    }

    private static func awdlAddress() -> Data? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var cursor = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == "awdl0", let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let bytes = withUnsafeBytes(of: &ip) { Data($0) }
            if bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return bytes }
        }
        return nil
    }
}
