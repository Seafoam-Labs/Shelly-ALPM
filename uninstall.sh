#!/bin/bash

# Shelly-ALPM Uninstaller
# Removes files installed by local-install.sh or web-install.sh

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

INSTALL_DIR="/opt/shelly"

echo "Removing Shelly installation..."

# Remove shelly-ui from /usr/bin (symlink from install.sh/local-install.sh OR binary from web-install.sh)
if [ -L /usr/bin/shelly-ui ] || [ -f /usr/bin/shelly-ui ]; then
    echo "Removing /usr/bin/shelly-ui"
    rm -f /usr/bin/shelly-ui
fi

# Remove shelly from /usr/bin (symlink from install.sh/local-install.sh OR binary from web-install.sh)
if [ -L /usr/bin/shelly ] || [ -f /usr/bin/shelly ]; then
    echo "Removing /usr/bin/shelly"
    rm -f /usr/bin/shelly
fi

# Remove shelly from /usr/bin (symlink from install.sh/local-install.sh OR binary from web-install.sh)
if [ -L /usr/bin/shelly-notifications ] || [ -f /usr/bin/shelly-notifications ]; then
    echo "Removing /usr/bin/shelly-notifications "
    rm -f /usr/bin/shelly-notifications 
fi

# Remove Flatpak integration helper
if [ -f /usr/bin/shelly-flatpak-integrate ]; then
    echo "Removing /usr/bin/shelly-flatpak-integrate"
    rm -f /usr/bin/shelly-flatpak-integrate
fi

# Remove Polkit policy
if [ -f /usr/share/polkit-1/actions/com.shellyorg.shelly.policy ]; then
    echo "Removing Polkit policy"
    rm -f /usr/share/polkit-1/actions/com.shellyorg.shelly.policy
fi

# Remove native libraries installed by web-install.sh
#check both lib and bin locations from older versions.
if [ -f /usr/bin/libSkiaSharp.so ]; then
    echo "Removing /usr/bin/libSkiaSharp.so"
    rm -f /usr/bin/libSkiaSharp.so
fi

if [ -f /usr/bin/libHarfBuzzSharp.so ]; then
    echo "Removing /usr/bin/libHarfBuzzSharp.so"
    rm -f /usr/bin/libHarfBuzzSharp.so
fi

if [ -f /usr/lib/libSkiaSharp.so ]; then
    echo "Removing /usr/lib/libSkiaSharp.so"
    rm -f /usr/lib/libSkiaSharp.so
fi

if [ -f /usr/lib/libHarfBuzzSharp.so ]; then
    echo "Removing /usr/lib/libHarfBuzzSharp.so"
    rm -f /usr/lib/libHarfBuzzSharp.so
fi

# Remove desktop entry
if [ -f /usr/share/applications/com.shellyorg.shelly.desktop ]; then
    echo "Removing desktop entry"
    rm -f /usr/share/applications/com.shellyorg.shelly.desktop
fi
# Remove old desktop entry
if [ -f /usr/share/applications/shelly.desktop ]; then
    echo "Removing broken pre-GTK desktop entry"
    rm -f /usr/share/applications/shelly.desktop
fi

# Remove icon
if [ -f /usr/share/icons/hicolor/256x256/apps/shelly.png ]; then
    echo "Removing icon"
    rm -f /usr/share/icons/hicolor/256x256/apps/shelly.png
fi

# Remove installation directory
if [ -d "$INSTALL_DIR" ]; then
    echo "Removing installation directory: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
fi

# Remove user-specific files
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Remove desktop shortcut
USER_DESKTOP="$USER_HOME/Desktop"
if [ -f "$USER_DESKTOP/shelly.desktop" ]; then
    echo "Removing desktop shortcut for user: $REAL_USER"
    rm -f "$USER_DESKTOP/shelly.desktop"
fi

# Remove notification service shortcut
if [ -f "$USER_DESKTOP/shelly-notifications.desktop" ]; then
    echo "Removing desktop shortcut for user: $REAL_USER"
    rm -f "$USER_DESKTOP/shelly-notifications.desktop"
fi

# Remove user config directory (~/.local/share/Shelly)
USER_CONFIG_DIR="$USER_HOME/.local/share/Shelly"
if [ -d "$USER_CONFIG_DIR" ]; then
    echo "Removing user config directory: $USER_CONFIG_DIR"
    rm -rf "$USER_CONFIG_DIR"
fi

# Remove user cache directory (~/.cache/Shelly)
USER_CACHE_DIR="$USER_HOME/.cache/Shelly"
if [ -d "$USER_CACHE_DIR" ]; then
    echo "Removing user cache directory: $USER_CACHE_DIR"
    rm -rf "$USER_CACHE_DIR"
fi

echo "Uninstallation complete!"
