import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

private func lgWebOSPowerCallback(_ context: UnsafeMutableRawPointer?, _ service: io_service_t,
                                 _ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let owner = Unmanaged<LGWebOSPowerService>.fromOpaque(context).takeUnretainedValue()
    let token = Int(bitPattern: argument)
    MainActor.assumeIsolated { owner.handle(message: message, token: token) }
}

/// Power records survive HDMI disappearance while the TV is in standby.
@MainActor
final class LGWebOSPowerService {
    static let shared = LGWebOSPowerService()
    private static let log = Logger(subsystem: "com.crisp.app", category: "lg-power")
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var wakeTask: Task<Void, Never>?
    private var hosts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "crisp.webos.powerHosts") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "crisp.webos.powerHosts") }
    }
    var configuredHosts: [String] { Array(Set(hosts.values)).sorted() }

    func clearShortcuts(matching shortcut: KeyboardShortcut) {
        for host in configuredHosts {
            var preferences = LGWebOSDevicePreferences.load(host: host)
            preferences.inputShortcuts = preferences.inputShortcuts.filter { !$0.value.sameKeys(as: shortcut) }
            preferences.save(host: host)
            for controller in VolumeService.shared.networkControllers.values where controller.host == host {
                controller.devicePreferences = preferences
            }
        }
    }

    func host(for displayID: UInt32) -> String? {
        let mapping = UserDefaults.standard.dictionary(forKey: "crisp.webos.displayHosts") as? [String: String] ?? [:]
        guard let host = mapping[String(displayID)], configuredHosts.contains(host) else { return nil }
        return host
    }

    func setHost(_ host: String, for uuid: String, displayID: UInt32) {
        var current = hosts
        if host.isEmpty { current.removeValue(forKey: uuid) } else { current[uuid] = host }
        hosts = current
        var mapping = UserDefaults.standard.dictionary(forKey: "crisp.webos.displayHosts") as? [String: String] ?? [:]
        if host.isEmpty { mapping.removeValue(forKey: String(displayID)) } else { mapping[String(displayID)] = host }
        UserDefaults.standard.set(mapping, forKey: "crisp.webos.displayHosts")
        HotkeyService.shared.syncRegistrations()
    }

    func switchInput(host: String, input: String) async throws {
        guard configuredHosts.contains(host) else { throw LGWebOSDeviceError(message: "TV is not configured") }
        let existing = VolumeService.shared.networkControllers.values.first(where: { $0.host == host })
        let controller = existing ?? LGWebOSVolumeController(host: host)
        defer { if existing == nil { controller.disconnect() } }
        if existing == nil { controller.connect() }
        let deadline = ContinuousClock.now + .seconds(8)
        while !controller.ready && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard controller.ready else { throw LGWebOSDeviceError(message: "TV is not connected") }
        try await controller.switchTVInput(input)
    }

    func start() {
        guard root == 0 else { return }
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, lgWebOSPowerCallback, &notifier)
        if root != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else { Self.log.error("Unable to register LG TV sleep/wake notifications") }
    }

    fileprivate func handle(message: UInt32, token: Int) {
        switch message {
        case CrispIOCanSystemSleep: IOAllowPowerChange(root, token)
        case CrispIOSystemWillSleep:
            wakeTask?.cancel()
            Task {
                // Each TV gets a fresh input check and a bounded request before
                // acknowledging sleep. Do not delay sleep for offline displays.
                for (uuid, host) in hosts {
                    let preferences = LGWebOSDevicePreferences.load(host: host)
                    guard preferences.powerSync, preferences.extendedControls,
                          let controller = VolumeService.shared.networkControllers[uuid], controller.ready else { continue }
                    do { try await controller.sleepTVIfOnMacInput() }
                    catch { Self.log.notice("TV sleep skipped: \(error.localizedDescription, privacy: .public)") }
                }
                IOAllowPowerChange(root, token)
            }
        case CrispIOSystemHasPoweredOn:
            wakeTask?.cancel()
            wakeTask = Task {
                for (uuid, host) in hosts {
                    let preferences = LGWebOSDevicePreferences.load(host: host)
                    guard preferences.powerSync, preferences.extendedControls, preferences.canSyncPower else { continue }
                    let existing = VolumeService.shared.networkControllers[uuid]
                    let controller = existing ?? LGWebOSVolumeController(host: host)
                    do { try await controller.wakeTV() }
                    catch { Self.log.notice("TV wake failed: \(error.localizedDescription, privacy: .public)") }
                    if existing == nil { controller.disconnect() }
                }
            }
        default: break
        }
    }
}
