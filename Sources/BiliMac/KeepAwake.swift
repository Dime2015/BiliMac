import Foundation
import IOKit.pwr_mgt

/// 播放时不休眠: while a video or live room is playing (or buffering to play), keeps the display on and the Mac
/// awake, so it doesn't dim and sleep halfway through because nobody touched the keyboard or mouse. AVPlayer's
/// own guard did not hold here (the Mac still slept during playback), so this takes an explicit power assertion.
/// Released as soon as nothing is playing, so a paused video lets the Mac sleep as usual.
final class KeepAwake: @unchecked Sendable {
    static let shared = KeepAwake()

    private let lock = NSLock()
    private var playing: Set<ObjectIdentifier> = []
    private var assertion: IOPMAssertionID = 0
    private var held = false

    /// Reports whether `owner` (a player) is playing. Call with false when it stops or goes away.
    func set(_ owner: AnyObject, playing on: Bool) { set(ObjectIdentifier(owner), playing: on) }

    func set(_ id: ObjectIdentifier, playing on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { playing.insert(id) } else { playing.remove(id) }
        apply()
    }

    /// Re-checks after the setting changes.
    func settingChanged() {
        lock.lock(); defer { lock.unlock() }
        apply()
    }

    private func apply() {
        let want = !playing.isEmpty && AppSettings.shared.keepAwake
        guard want != held else { return }
        if want {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "BiliMac is playing a video" as CFString, &id)
            guard r == kIOReturnSuccess else { log("keep awake: assertion failed (\(r))"); return }
            assertion = id
            held = true
        } else {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}
