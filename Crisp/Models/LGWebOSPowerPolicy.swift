import Foundation

enum LGWebOSPowerPolicy {
    static func shouldSleep(enabled: Bool, preferences: LGWebOSDevicePreferences, currentInput: String?) -> Bool {
        enabled && preferences.extendedControls && preferences.canSyncPower && currentInput == preferences.macInput
    }
}
