#!/usr/bin/env bash
# uninstall.sh: Remove Remote Guardian and restore default sleep settings

echo "=== Uninstalling Remote Guardian ==="

STATE_FILE="$HOME/.remote-guardian.state"
if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    sleep 1
fi

# 1. Restore sleep if still disabled
if /usr/bin/pmset -g | grep -qE "SleepDisabled[[:space:]]+1"; then
    echo "Restoring standard macOS sleep behavior..."
    sudo /usr/bin/pmset disablesleep 0
fi

# 2. Remove sudoers rule if present
if [ -f "/etc/sudoers.d/remote-guardian" ]; then
    echo "Removing /etc/sudoers.d/remote-guardian..."
    sudo rm -f "/etc/sudoers.d/remote-guardian"
fi

# 3. Terminate running instance
pkill -f "Remote Guardian" 2>/dev/null || true

# 4. Remove from Login Items
osascript -e 'tell application "System Events" to delete (every login item whose name is "Remote Guardian")' 2>/dev/null || true

# 5. Remove application bundle
APP_BUNDLE="$HOME/Applications/Remote Guardian.app"
if [ -d "$APP_BUNDLE" ]; then
    rm -rf "$APP_BUNDLE"
    echo "Removed $APP_BUNDLE"
fi

# 6. Remove CLI
for loc in "/opt/homebrew/bin/remote-guardian" "/usr/local/bin/remote-guardian" "$HOME/.local/bin/remote-guardian" "$HOME/bin/remote-guardian"; do
    if [ -f "$loc" ]; then
        rm -f "$loc"
        echo "Removed $loc"
    fi
done

echo "✓ Uninstallation complete."
