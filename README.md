# ⚡ Remote Guardian for macOS

**Keep your MacBook awake with the lid closed for remote development, background tasks, and AI coding agents.**

A lightweight, zero-dependency native macOS Menu Bar app and CLI companion engineered for developers running remote development sessions, background coding agents, headless SSH/tmux tasks, local model inference, or long builds on the go.

---

## 💡 The Problem

When you kick off long-running developer tasks and want to monitor or steer them remotely from your phone, tablet, or another machine, closing your MacBook lid immediately kills your session.

Closing a MacBook lid without an external monitor attached triggers hardware-level **clamshell sleep**, which:
1. Suspends the CPU and halts all local processes, servers, and terminals.
2. Drops your Wi-Fi and network connections.
3. Disconnects remote SSH, web dashboards, and agent sessions.

Standard tools like `caffeinate` and Mac App Store utilities (like *KeepingYouAwake* or base *Amphetamine*) only prevent **idle sleep** while the lid is open. The moment the physical lid sensor closes, macOS ignores standard user-space power assertions and forces the machine to sleep.

---

## 🏆 How Remote Guardian Compares

| Feature / Capability | `caffeinate` / *KeepingYouAwake* | *Amphetamine* (App Store) | Other GitHub Wrappers (*Awayke*, *Sleepless*, *LidAwake*) | **⚡ Remote Guardian** |
| :--- | :---: | :---: | :---: | :---: |
| **Prevents Lid-Closed Sleep (No Display)** | ❌ No | ⚠️ Requires external *Enhancer* | ✅ Yes (`pmset`) | ✅ **Yes (`pmset`)** |
| **Zero Permanent Root LaunchDaemons** | ✅ Yes | ❌ Installs background plugin | ❌ Often installs `/Library/LaunchDaemons` | ✅ **Yes (Ephemeral Guardian)** |
| **Single Authentication (Passwordless OFF)** | N/A | ✅ Yes | ❌ Prompts password on ON **and** OFF | ✅ **Yes (Authenticate once)** |
| **Backpack Guard (Auto-Sleep on Unplug)** | ❌ No | ⚠️ Complex trigger setup | ❌ No | ✅ **Built-in (Default ON)** |
| **Hard ≤15% Critical Battery Cutoff** | ❌ No | ✅ Yes | ⚠️ Partial | ✅ **Built-in Hardware Safeguard** |
| **Safe Quit Prompt (Prevents Orphaned Lock)** | ✅ Yes | ✅ Yes | ❌ Often leaves kernel sleep disabled | ✅ **Built-in Modal Guard** |
| **Unified Native Menu Bar + Scriptable CLI** | ❌ CLI or GUI only | ❌ GUI only | ❌ GUI only | ✅ **Both Included** |

---

## ✨ Key Engineering Highlights

### 1. Ephemeral Guardian Architecture (Single-Auth, Zero Permanent Daemons)
Most utilities that toggle `pmset disablesleep` either force you to install a permanent privileged root daemon in `/Library/PrivilegedHelperTools`, or prompt for your administrator password **twice** (once to turn ON, and again to turn OFF)—which also means countdown timers fail if your lid is closed when the timer expires!

**Remote Guardian** solves this cleanly:
* When you turn Keep-Awake **ON**, you authenticate **once** via macOS Touch ID / password prompt.
* That single authorization enables `pmset disablesleep 1` and launches a tiny, self-terminating **Ephemeral Guardian** loop that lives *only* while Keep-Awake is active.
* When you click **Turn OFF**, when a countdown timer expires while your lid is shut, or when you unplug your charger, the guardian automatically restores `pmset disablesleep 0` and exits cleanly—**with zero second password prompt and zero permanent background daemons.**

### 2. 🛡️ Backpack Guard (Auto-Sleep When Unplugged)
The #1 danger of disabling clamshell sleep on a laptop is forgetting it's enabled, unplugging your MacBook, and sliding it into a backpack where it overheats.
* With **Backpack Guard** enabled (on by default), the moment you unplug your MagSafe/USB-C power cord to pack up your laptop, the Ephemeral Guardian detects the transition from `AC Power` to `Battery Power` and **automatically restores standard macOS sleep**.
* Even if you explicitly allow battery operation, a hard **≤15% battery floor** ensures your Mac goes to sleep safely before draining flat.

### 3. ⏱️ Built-in Countdown Timers (`1h`, `2h`, `4h`, `8h`, `Indefinite`)
Set a session duration directly from the Menu Bar or CLI (`remote-guardian on 2h`). Because the Ephemeral Guardian manages cleanup internally, timers work reliably even while the laptop lid is closed and locked. You can also update or extend active timers on the fly without re-authenticating.

### 4. ⚡ Live System & Power Telemetry
The Menu Bar dropdown and CLI inspect your system in real time and display:
* Current power source and exact battery percentage (`⚡ Power: AC Connected (100%)`).
* Active countdown timer status (`1h`, `2h`, `4h`, `8h`, or `Indefinite`).
* Clamshell sleep prevention status.

---

## 📦 Quick Installation (10 Seconds)

Requires macOS 13.0+ and Xcode Command Line Tools (`swiftc`).

```bash
git clone https://github.com/robdoit/remote-guardian.git
cd remote-guardian
./install.sh
```

`./install.sh` compiles the native Swift menu bar app (`arm64` or `x86_64`), applies an ad-hoc code signature, installs the app bundle into `~/Applications/Remote Guardian.app`, installs the `remote-guardian` CLI into your `PATH`, and launches the menu bar icon immediately.

---

## 🖥️ Usage

### Menu Bar App
Look for the bolt icon in the top-right macOS menu bar:
* **⚡ Solid Bolt:** Remote Guardian is **ACTIVE** (safe to close lid).
* **⚡⃠ Slashed Bolt:** Remote Guardian is **OFF** (standard macOS sleep).

Click the icon to:
* **Turn ON Keep-Awake** (Indefinitely, or for **1h / 2h / 4h / 8h**).
* **Update Active Timer** on the fly without re-authenticating.
* Toggle **🛡️ Auto-Sleep When Unplugged (Backpack Guard)**.
* Check live **AC Power** and **Battery %** status.
* **Turn OFF Keep-Awake** instantly (no password prompt needed).

### CLI (`remote-guardian`)

```bash
# Keep awake indefinitely (with Backpack Guard ON by default)
remote-guardian on

# Keep awake for a specific duration (auto-sleeps when timer expires)
remote-guardian on 2h
remote-guardian on 45m

# Keep awake even if unplugged (still auto-sleeps at ≤15% battery)
remote-guardian on 1h --allow-battery

# Check live status, countdown timer, and battery %
remote-guardian status

# Restore normal macOS sleep immediately (passwordless when guardian is active)
remote-guardian off

# Launch the Menu Bar App if closed
remote-guardian menu
```

---

## ⚙️ Start Automatically at Login (Optional)

1. Open **System Settings** > **General** > **Login Items & Extensions**.
2. Under **Open at Login**, click **`+`**.
3. Select `~/Applications/Remote Guardian.app`.

---

## ⚠️ Safety Notice

> [!CAUTION]
> **Thermal Safety:** Never place your MacBook inside an enclosed backpack, sleeve, or bag while Keep-Awake is active. Without airflow, an awake laptop can generate excessive heat. Keep **Backpack Guard** enabled so unplugging your charger automatically restores sleep before you pack your machine away.

---

## 🗑️ Uninstallation

To cleanly remove the Menu Bar app, remove the CLI tool, and guarantee default macOS sleep settings are restored:

```bash
./uninstall.sh
```

---

## 📄 License

MIT License — see [LICENSE](LICENSE).
