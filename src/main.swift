import Cocoa
import LocalAuthentication

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var isMenuOpen = false

    let stateFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".remote-guardian.state")
    let unplugGuardDefaultsKey = "RemoteGuardianUnplugGuard"
    let requireTouchIDDefaultsKey = "RemoteGuardianRequireTouchID"

    var unplugGuardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: unplugGuardDefaultsKey) == nil {
                return true // Default ON for safety
            }
            return UserDefaults.standard.bool(forKey: unplugGuardDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: unplugGuardDefaultsKey)
            if FileManager.default.fileExists(atPath: stateFilePath) {
                writeStateFile(expiresAt: currentExpiresAt(), unplugGuard: newValue)
            }
            updateStatus()
        }
    }

    var requireTouchID: Bool {
        get {
            if UserDefaults.standard.object(forKey: requireTouchIDDefaultsKey) == nil {
                return true // Default ON: uses native Touch ID fingerprint prompt
            }
            return UserDefaults.standard.bool(forKey: requireTouchIDDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: requireTouchIDDefaultsKey)
            updateStatus()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Menu bar only (no Dock icon)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateStatus()

        // Poll every 2 seconds for timer expiration, Backpack Guard (unplug), and battery floor
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAutomaticSafeguards()
            if !self.isMenuOpen {
                self.updateStatus()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        let active = isSleepDisabled()
        let power = getPowerState()
        let remaining = remainingTimeString()
        let touchIDReady = isPasswordlessPmsetConfigured()
        let launchAtLogin = isLaunchAtLoginEnabled()
        populateMenu(menu, active: active, power: power, remaining: remaining, touchIDReady: touchIDReady, launchAtLogin: launchAtLogin)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - System Inspection

    func isSleepDisabled() -> Bool {
        let output = runCommand("/usr/bin/pmset", arguments: ["-g"])
        return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    func isPasswordlessPmsetConfigured() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func getPowerState() -> (isAC: Bool, percentage: Int?, description: String) {
        let output = runCommand("/usr/bin/pmset", arguments: ["-g", "batt"])
        var pct: Int? = nil
        if let match = output.range(of: #"[0-9]+%"#, options: .regularExpression) {
            let numStr = output[match].dropLast()
            pct = Int(numStr)
        }
        let pctText = pct != nil ? " (\(pct!)%)" : ""
        if output.contains("AC Power") {
            return (true, pct, "⚡ Power: AC Connected\(pctText)")
        } else if output.contains("Battery Power") {
            return (false, pct, "🔋 Power: On Battery\(pctText) — Plug in charger!")
        }
        return (false, pct, "Power: Unknown")
    }

    func runCommand(_ launchPath: String, arguments: [String]) -> String {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    @discardableResult
    func runSudoPmset(_ disableVal: Int) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "/usr/bin/pmset", "disablesleep", "\(disableVal)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Native App Safeguards (Timer, Backpack Guard, Battery Cutoff)

    var wasOnACPower = false

    func checkAutomaticSafeguards() {
        guard isSleepDisabled() else {
            wasOnACPower = false
            return
        }

        let power = getPowerState()
        if power.isAC {
            wasOnACPower = true
        } else {
            // 1. Backpack Guard: transitioned from AC Power -> Battery Power
            if unplugGuardEnabled && wasOnACPower {
                wasOnACPower = false
                silentAutoDisableSleep()
                return
            }
            // 2. Hard ≤15% Critical Battery Cutoff
            if let pct = power.percentage, pct <= 15 {
                silentAutoDisableSleep()
                return
            }
        }

        // 3. Countdown Timer Expiration
        let exp = currentExpiresAt()
        if exp > 0 && Int(Date().timeIntervalSince1970) >= exp {
            silentAutoDisableSleep()
            return
        }
    }

    func silentAutoDisableSleep() {
        try? FileManager.default.removeItem(atPath: stateFilePath)
        if isPasswordlessPmsetConfigured() {
            _ = runSudoPmset(0)
        }
        updateStatus()
    }

    // MARK: - Guardian State Management

    func currentExpiresAt() -> Int {
        guard let content = try? String(contentsOfFile: stateFilePath, encoding: .utf8) else {
            return 0
        }
        for line in content.split(separator: "\n") {
            if line.hasPrefix("EXPIRES_AT=") {
                let val = line.dropFirst("EXPIRES_AT=".count)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    func remainingTimeString() -> String? {
        let exp = currentExpiresAt()
        guard exp > 0 else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let diff = exp - now
        if diff <= 0 { return nil }
        let hours = diff / 3600
        let mins = (diff % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(mins)m remaining"
        } else {
            return "\(max(1, mins))m remaining"
        }
    }

    func writeStateFile(expiresAt: Int, unplugGuard: Bool) {
        let content = "EXPIRES_AT=\(expiresAt)\nUNPLUG_GUARD=\(unplugGuard ? 1 : 0)\nMIN_BATTERY=15\n"
        try? content.write(toFile: stateFilePath, atomically: true, encoding: .utf8)
    }

    // MARK: - UI Updates

    func updateStatus() {
        let active = isSleepDisabled()
        let power = getPowerState()
        let remaining = remainingTimeString()
        let touchIDReady = isPasswordlessPmsetConfigured()
        let launchAtLogin = isLaunchAtLoginEnabled()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let button = self.statusItem.button {
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                if active {
                    button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Remote Guardian Active")?.withSymbolConfiguration(symbolConfig)
                    button.toolTip = "Remote Guardian: ACTIVE (Lid sleep disabled)"
                } else {
                    button.image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: "Remote Guardian Inactive")?.withSymbolConfiguration(symbolConfig)
                    button.toolTip = "Remote Guardian: OFF (Standard sleep enabled)"
                }
            }

            if !self.isMenuOpen, let menu = self.statusItem.menu {
                self.populateMenu(menu, active: active, power: power, remaining: remaining, touchIDReady: touchIDReady, launchAtLogin: launchAtLogin)
            }
        }
    }

    func populateMenu(
        _ menu: NSMenu,
        active: Bool,
        power: (isAC: Bool, percentage: Int?, description: String),
        remaining: String?,
        touchIDReady: Bool,
        launchAtLogin: Bool
    ) {
        menu.removeAllItems()

        // 1. Status Header
        let statusTitle: String
        if active {
            if let rem = remaining {
                statusTitle = "🟢 Remote Guardian: ACTIVE (\(rem))"
            } else {
                statusTitle = "🟢 Remote Guardian: ACTIVE (Indefinite)"
            }
        } else {
            statusTitle = "⚪ Remote Guardian: OFF (Standard Sleep)"
        }
        let titleItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // 2. One-Time Touch ID Setup Banner (if not configured yet)
        if !touchIDReady {
            let setupItem = NSMenuItem(
                title: "👆 Enable Touch ID (One-Time Password Setup)...",
                action: #selector(setupTouchIDOnly),
                keyEquivalent: ""
            )
            setupItem.target = self
            menu.addItem(setupItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 3. Primary Actions & Timers
        if active {
            let toggleOff = NSMenuItem(
                title: "Turn OFF Keep-Awake (Allow Normal Sleep)",
                action: #selector(toggleSleepOff),
                keyEquivalent: ""
            )
            toggleOff.target = self
            menu.addItem(toggleOff)

            menu.addItem(NSMenuItem.separator())
            let timerHeader = NSMenuItem(title: "Update Active Timer:", action: nil, keyEquivalent: "")
            timerHeader.isEnabled = false
            menu.addItem(timerHeader)
        } else {
            let turnOnIndefinite = NSMenuItem(
                title: "⚡ Turn ON Keep-Awake (Indefinitely)",
                action: #selector(turnOnIndefinite),
                keyEquivalent: ""
            )
            turnOnIndefinite.target = self
            menu.addItem(turnOnIndefinite)
        }

        let durations: [(String, Selector, Int)] = [
            ("⏱️ Keep Awake for 1 Hour", #selector(turnOn1h), 3600),
            ("⏱️ Keep Awake for 2 Hours", #selector(turnOn2h), 7200),
            ("⏱️ Keep Awake for 4 Hours", #selector(turnOn4h), 14400),
            ("⏱️ Keep Awake for 8 Hours", #selector(turnOn8h), 28800)
        ]
        for (label, selector, _) in durations {
            let item = NSMenuItem(title: label, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if active && remaining != nil {
            let clearTimer = NSMenuItem(title: "♾️ Switch to Indefinite (No Timer)", action: #selector(turnOnIndefinite), keyEquivalent: "")
            clearTimer.target = self
            menu.addItem(clearTimer)
        }

        menu.addItem(NSMenuItem.separator())

        // 4. Preferences (Backpack Guard + Touch ID Toggle)
        let guardItem = NSMenuItem(
            title: "🛡️ Auto-Sleep When Unplugged (Backpack Guard)",
            action: #selector(toggleUnplugGuard),
            keyEquivalent: ""
        )
        guardItem.target = self
        guardItem.state = unplugGuardEnabled ? .on : .off
        menu.addItem(guardItem)

        if touchIDReady {
            let touchIDItem = NSMenuItem(
                title: "👆 Require Touch ID When Toggling (Uncheck for 1-Click)",
                action: #selector(toggleRequireTouchID),
                keyEquivalent: ""
            )
            touchIDItem.target = self
            touchIDItem.state = requireTouchID ? .on : .off
            menu.addItem(touchIDItem)
        }

        let launchItem = NSMenuItem(
            title: "🚀 Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Live Power & Safety Telemetry
        let powerItem = NSMenuItem(title: power.description, action: nil, keyEquivalent: "")
        powerItem.isEnabled = false
        menu.addItem(powerItem)

        let cutoffNote = NSMenuItem(title: "• Auto-cutoff at ≤15% battery to prevent shutdown", action: nil, keyEquivalent: "")
        cutoffNote.isEnabled = false
        menu.addItem(cutoffNote)

        let bagNote = NSMenuItem(title: "• Never place an awake laptop inside an enclosed bag", action: nil, keyEquivalent: "")
        bagNote.isEnabled = false
        menu.addItem(bagNote)

        menu.addItem(NSMenuItem.separator())

        // 6. Quit
        let quitItem = NSMenuItem(title: "Quit Remote Guardian", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Touch ID & One-Time Sudoers Setup

    let sudoersSetupScript = """
    mkdir -p /etc/sudoers.d && \
    printf '%s\\n' '%admin ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0' > /tmp/rg_sudoers_tmp && \
    chown root:wheel /tmp/rg_sudoers_tmp && \
    chmod 0440 /tmp/rg_sudoers_tmp && \
    /usr/sbin/visudo -cf /tmp/rg_sudoers_tmp >/dev/null 2>&1 && \
    mv /tmp/rg_sudoers_tmp /etc/sudoers.d/remote-guardian && \
    if [ ! -f /etc/pam.d/sudo_local ]; then \
        printf '# sudo_local: Touch ID for sudo\\nauth       sufficient     pam_tid.so\\n' > /etc/pam.d/sudo_local && \
        chown root:wheel /etc/pam.d/sudo_local && \
        chmod 0444 /etc/pam.d/sudo_local; \
    fi
    """

    @objc func setupTouchIDOnly() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.runPrivilegedShellScript(self.sudoersSetupScript)
            DispatchQueue.main.async {
                self.updateStatus()
            }
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        let script = "tell application \"System Events\" to get (exists (login item \"Remote Guardian\"))"
        let out = runCommand("/usr/bin/osascript", arguments: ["-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "true"
    }

    @objc func toggleLaunchAtLogin() {
        let isEnabled = isLaunchAtLoginEnabled()
        let appPath = Bundle.main.bundlePath
        let script: String
        if isEnabled {
            script = "tell application \"System Events\" to delete (every login item whose name is \"Remote Guardian\")"
        } else {
            script = "tell application \"System Events\" to make login item at end with properties {path:\"\(appPath)\", hidden:false, name:\"Remote Guardian\"}"
        }
        _ = runCommand("/usr/bin/osascript", arguments: ["-e", script])
        updateStatus()
    }

    func authenticateWithTouchID(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            NSApp.activate(ignoringOtherApps: true)
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            completion(true)
        }
    }

    // MARK: - Actions

    @objc func turnOnIndefinite() { enableKeepAwake(durationSeconds: 0) }
    @objc func turnOn1h() { enableKeepAwake(durationSeconds: 3600) }
    @objc func turnOn2h() { enableKeepAwake(durationSeconds: 7200) }
    @objc func turnOn4h() { enableKeepAwake(durationSeconds: 14400) }
    @objc func turnOn8h() { enableKeepAwake(durationSeconds: 28800) }

    @objc func toggleUnplugGuard() {
        unplugGuardEnabled.toggle()
    }

    @objc func toggleRequireTouchID() {
        if requireTouchID {
            // Verify with Touch ID before disabling Touch ID requirement
            authenticateWithTouchID(reason: "enable Instant 1-Click Mode in Remote Guardian") { [weak self] ok in
                if ok {
                    self?.requireTouchID = false
                }
            }
        } else {
            requireTouchID = true
        }
    }

    func enableKeepAwake(durationSeconds: Int) {
        let expiresAt = durationSeconds > 0 ? Int(Date().timeIntervalSince1970) + durationSeconds : 0

        // If already active, just update timer in state file without re-prompting!
        if isSleepDisabled() {
            writeStateFile(expiresAt: expiresAt, unplugGuard: unplugGuardEnabled)
            updateStatus()
            return
        }

        writeStateFile(expiresAt: expiresAt, unplugGuard: unplugGuardEnabled)
        wasOnACPower = getPowerState().isAC

        if isPasswordlessPmsetConfigured() {
            let executeTurnOn = { [weak self] in
                guard let self = self else { return }
                let ok = self.runSudoPmset(1)
                if !ok {
                    try? FileManager.default.removeItem(atPath: self.stateFilePath)
                } else {
                    self.startBackgroundGuardianIfNeeded()
                }
                self.updateStatus()
            }

            if requireTouchID {
                authenticateWithTouchID(reason: "turn ON Remote Guardian Keep-Awake") { ok in
                    if ok {
                        executeTurnOn()
                    } else {
                        try? FileManager.default.removeItem(atPath: self.stateFilePath)
                    }
                }
            } else {
                executeTurnOn()
            }
        } else {
            // First-time setup: configure Touch ID sudoers rule AND turn on Keep-Awake in one go!
            let combinedCmd = "\(sudoersSetupScript) && /usr/bin/pmset disablesleep 1"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let ok = self.runPrivilegedShellScript(combinedCmd)
                if !ok {
                    try? FileManager.default.removeItem(atPath: self.stateFilePath)
                } else {
                    self.startBackgroundGuardianIfNeeded()
                }
                DispatchQueue.main.async {
                    self.updateStatus()
                }
            }
        }
    }

    func startBackgroundGuardianIfNeeded() {
        // Also run a lightweight user-space background monitor so CLI & GUI stay synced even if app is quit
        let escapedStateFile = stateFilePath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        nohup /bin/bash -c '
        STATE_FILE="\(escapedStateFile)"
        cleanup() {
            /usr/bin/sudo -n /usr/bin/pmset disablesleep 0 >/dev/null 2>&1
            rm -f "$STATE_FILE" >/dev/null 2>&1
            exit 0
        }
        trap cleanup EXIT INT TERM
        WAS_AC=0
        if /usr/bin/pmset -g batt | grep -q "AC Power"; then WAS_AC=1; fi
        while [ -f "$STATE_FILE" ]; do
            if ! /usr/bin/pmset -g | grep -qE "SleepDisabled[[:space:]]+1"; then
                rm -f "$STATE_FILE" >/dev/null 2>&1
                exit 0
            fi
            EXP=$(grep "^EXPIRES_AT=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | tr -dc "0-9")
            GUARD=$(grep "^UNPLUG_GUARD=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | tr -dc "0-9")
            NOW=$(date +%s)
            if [ -n "$EXP" ] && [ "$EXP" -gt 0 ] && [ "$NOW" -ge "$EXP" ]; then
                cleanup
            fi
            BATT_OUT=$(/usr/bin/pmset -g batt 2>/dev/null)
            if echo "$BATT_OUT" | grep -q "AC Power"; then
                WAS_AC=1
            elif echo "$BATT_OUT" | grep -q "Battery Power"; then
                if [ "${GUARD:-1}" = "1" ] && [ "$WAS_AC" = "1" ]; then
                    cleanup
                fi
                PCT=$(echo "$BATT_OUT" | grep -oE "[0-9]+%" | head -n1 | tr -dc "0-9")
                if [ -n "$PCT" ] && [ "$PCT" -le 15 ]; then
                    cleanup
                fi
            fi
            sleep 1
        done
        cleanup
        ' >/dev/null 2>&1 </dev/null &
        """
        _ = runCommand("/bin/bash", arguments: ["-c", script])
    }

    @objc func toggleSleepOff() {
        if isPasswordlessPmsetConfigured() && requireTouchID {
            authenticateWithTouchID(reason: "turn OFF Remote Guardian Keep-Awake") { [weak self] ok in
                if ok {
                    self?.disableKeepAwake(completion: nil)
                }
            }
        } else {
            disableKeepAwake(completion: nil)
        }
    }

    func disableKeepAwake(completion: (() -> Void)?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            try? FileManager.default.removeItem(atPath: self.stateFilePath)

            if self.isPasswordlessPmsetConfigured() {
                _ = self.runSudoPmset(0)
            } else if self.isSleepDisabled() {
                _ = self.runPrivilegedShellScript("\(self.sudoersSetupScript) && /usr/bin/pmset disablesleep 0")
            }

            DispatchQueue.main.async {
                self.updateStatus()
                completion?()
            }
        }
    }

    func runPrivilegedShellScript(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escaped)\" with administrator privileges"
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            return errorInfo == nil
        }
        return false
    }

    @objc func quitApp() {
        if isSleepDisabled() {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Remote Guardian is Currently Active"
            alert.informativeText = "Your Mac is currently set to stay awake with the lid closed. Would you like to restore normal sleep before quitting Remote Guardian so your laptop doesn't overheat in a bag?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restore Normal Sleep & Quit")
            alert.addButton(withTitle: "Quit & Stay Awake")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                disableKeepAwake {
                    NSApp.terminate(nil)
                }
            } else if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
