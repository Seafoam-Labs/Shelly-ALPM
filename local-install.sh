#!/bin/bash

# Local Install Script for Shelly-ALPM
# This script builds and installs Shelly locally, similar to install.sh
# but starting from source code instead of pre-built binaries.

set -e  # Exit on any error

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)"
  exit 1
fi

INSTALL_DIR="/opt/shelly"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIG="Release"

echo "=========================================="
echo "Shelly Local Install Script"
echo "=========================================="
echo ""

# Check if dotnet is installed
if ! command -v dotnet &> /dev/null; then
    echo "Error: .NET SDK is not installed. Please install .NET 10.0 SDK first."
    exit 1
fi

# Check if msgfmt is installed (for translations)
if ! command -v msgfmt &> /dev/null; then
    echo "Warning: msgfmt not found. Translations might not be compiled."
fi

echo "Script directory: $SCRIPT_DIR"
echo "Install directory: $INSTALL_DIR"
echo ""

# Build Shelly-Notifications
echo "Building Shelly-Notifications..."
cd "$SCRIPT_DIR/Shelly-Notifications"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly-Notifications" -p:InstructionSet=x86-64
echo "Shelly-Notifications build complete."
echo ""

# Build Shelly.Gtk
echo "Building Shelly.Gtk..."
cd "$SCRIPT_DIR/Shelly.Gtk"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly.Gtk" -p:InstructionSet=x86-64
echo "Shelly.Gtk build complete."
echo ""

# Build Shelly.Cli
echo "Building Shelly.Cli..."
cd "$SCRIPT_DIR/Shelly.Cli"
dotnet publish -c $BUILD_CONFIG -r linux-x64 -o "$SCRIPT_DIR/publish/Shelly.Cli" -p:InstructionSet=x86-64
echo "Shelly.Cli build complete."
echo ""

# Create installation directory
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy Shelly-Notifications files
echo "Copying Shelly-Notifications files to $INSTALL_DIR"
cp -r "$SCRIPT_DIR/publish/Shelly-Notifications/"* "$INSTALL_DIR/"

# Copy Shelly.Gtk files (binary is named 'shelly-ui' due to AssemblyName)
echo "Copying Shelly.Gtk files to $INSTALL_DIR"
cp -r "$SCRIPT_DIR/publish/Shelly.Gtk/"* "$INSTALL_DIR/"

# Ensure translations are compiled
echo "Compiling translations..."
if command -v msgfmt &> /dev/null; then
    # Compile UI translations
    for po_file in "$SCRIPT_DIR/Shelly.Gtk/po/"*.po; do
        if [ -f "$po_file" ]; then
            lang=$(basename "$po_file" .po)
            mkdir -p "$SCRIPT_DIR/Shelly.Gtk/locale/$lang/LC_MESSAGES"
            msgfmt "$po_file" -o "$SCRIPT_DIR/Shelly.Gtk/locale/$lang/LC_MESSAGES/shelly-ui.mo"
        fi
    done

    # Compile tray service translations
    for po_file in "$SCRIPT_DIR/Shelly-Notifications/po/"*.po; do
        if [ -f "$po_file" ]; then
            lang=$(basename "$po_file" .po)
            mkdir -p "$SCRIPT_DIR/Shelly-Notifications/locale/$lang/LC_MESSAGES"
            msgfmt "$po_file" -o "$SCRIPT_DIR/Shelly-Notifications/locale/$lang/LC_MESSAGES/shelly-notifications.mo"
        fi
    done
fi

# Copy locale files
echo "Copying locale files..."
mkdir -p "$INSTALL_DIR/locale"

if [ -d "$SCRIPT_DIR/Shelly.Gtk/locale" ]; then
    cp -r "$SCRIPT_DIR/Shelly.Gtk/locale/"* "$INSTALL_DIR/locale/" 2>/dev/null || true
fi

if [ -d "$SCRIPT_DIR/Shelly-Notifications/locale" ]; then
    cp -r "$SCRIPT_DIR/Shelly-Notifications/locale/"* "$INSTALL_DIR/locale/" 2>/dev/null || true
fi

# Copy Shelly.Cli binary (output is named 'shelly' due to AssemblyName)
echo "Copying Shelly.Cli binary to $INSTALL_DIR"
cp "$SCRIPT_DIR/publish/Shelly.Cli/shelly" "$INSTALL_DIR/shelly"

# Copy the logo
echo "Copying logo..."
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo.png" "$INSTALL_DIR/"

# Create symlinks in /usr/bin so commands are available on PATH
echo "Creating symlinks in /usr/bin..."
ln -sf "$INSTALL_DIR/shelly-ui" /usr/bin/shelly-ui
ln -sf "$INSTALL_DIR/shelly" /usr/bin/shelly
ln -sf "$INSTALL_DIR/Shelly-Notifications" /usr/bin/shelly-notifications

# Install icons to standard location
echo "Installing icons to standard location..."
mkdir -p /usr/share/icons/hicolor/256x256/apps
mkdir -p /usr/share/icons/hicolor/symbolic/apps
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo.png" /usr/share/icons/hicolor/256x256/apps/shelly.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo-tray.png" /usr/share/icons/hicolor/256x256/apps/shelly-tray.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/shellylogo-update.png" /usr/share/icons/hicolor/256x256/apps/shelly-update.png
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/flatpak-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/flatpak-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/arch-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/arch-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/shelly-updates-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/shelly-updates-symbolic.svg
cp "$SCRIPT_DIR/Shelly.Gtk/Assets/svg/shelly-shell-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/shelly-shell-symbolic.svg

# Install translations to standard location
echo "Installing translations to /usr/share/locale..."

# Install UI translations
for lang_dir in "$SCRIPT_DIR/Shelly.Gtk/locale/"*; do
    if [ -d "$lang_dir" ] && [ -f "$lang_dir/LC_MESSAGES/shelly-ui.mo" ]; then
        lang=$(basename "$lang_dir")
        mkdir -p "/usr/share/locale/$lang/LC_MESSAGES"
        cp "$lang_dir/LC_MESSAGES/shelly-ui.mo" "/usr/share/locale/$lang/LC_MESSAGES/"
    fi
done

# Install tray service translations
for lang_dir in "$SCRIPT_DIR/Shelly-Notifications/locale/"*; do
    if [ -d "$lang_dir" ] && [ -f "$lang_dir/LC_MESSAGES/shelly-notifications.mo" ]; then
        lang=$(basename "$lang_dir")
        mkdir -p "/usr/share/locale/$lang/LC_MESSAGES"
        cp "$lang_dir/LC_MESSAGES/shelly-notifications.mo" "/usr/share/locale/$lang/LC_MESSAGES/"
    fi
done

# Create desktop entry
echo "Creating desktop entry"
cat <<EOF > /usr/share/applications/com.shellyorg.shelly.desktop
[Desktop Entry]
Name=Shelly
Comment=A Modern Arch Package Manager
Exec=/usr/bin/shelly-ui
Icon=shelly
Type=Application
Categories=System;Utility;
Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
Terminal=false
Actions=FlatpakInstall;FlatpakUpdate;FlatpakRemove;

[Desktop Action FlatpakInstall]
Name=Flatpak Install
Icon=flatpak-symbolic
Exec=/usr/bin/shelly-ui --page flatpak-install

[Desktop Action FlatpakUpdate]
Name=Flatpak Update
Icon=flatpak-symbolic
Exec=/usr/bin/shelly-ui --page flatpak-update

[Desktop Action FlatpakRemove]
Name=Flatpak Remove
Icon=flatpak-symbolic
Exec=/usr/bin/shelly-ui --page flatpak-remove
EOF

echo "Creating notifications entry"
cat <<EOF > /usr/share/applications/shelly-notifications.desktop
[Desktop Entry]
Name=Shelly Notifications
Comment=Notification service for Shelly package manager
Exec=/usr/bin/shelly-notifications
Icon=shelly-tray
Type=Application
Categories=System;Utility;
Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
Terminal=false
NoDisplay=true
EOF

# Install Flatpak integration helper
echo "Installing Flatpak integration helper..."
cat <<'SCRIPT' > /usr/bin/shelly-flatpak-integrate
#!/bin/bash
# Adds "Manage in Shelly" right-click action to Flatpak .desktop files
FLATPAK_DIRS=(
        "/var/lib/flatpak/exports/share/applications"
        "$HOME/.local/share/flatpak/exports/share/applications"
)
LOCAL_APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$LOCAL_APPS_DIR"

for dir in "${FLATPAK_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        for desktop_file in "$dir"/*.desktop; do
                [ -f "$desktop_file" ] || continue
                filename=$(basename "$desktop_file")
                dest="$LOCAL_APPS_DIR/$filename"

                [ -f "$dest" ] || cp "$desktop_file" "$dest"

                grep -q "ShellyManage" "$dest" && continue

                if grep -q "^Actions=" "$dest"; then
                        sed -i 's/^Actions=\(.*\)/Actions=\1ShellyManage;/' "$dest"
                else
                        sed -i '/^\[Desktop Entry\]/a Actions=ShellyManage;' "$dest"
                fi

                cat >> "$dest" << EOF

[Desktop Action ShellyManage]
Name=Manage in Shelly
Icon=shelly
Exec=/usr/bin/shelly-ui --page flatpak-install
EOF
        done
done

update-desktop-database "$LOCAL_APPS_DIR" 2>/dev/null || true
echo "Flatpak desktop entries patched with Shelly integration."
SCRIPT
chmod 755 /usr/bin/shelly-flatpak-integrate

# Install Polkit policy for privileged Shelly CLI execution via pkexec
echo "Installing Polkit policy..."
mkdir -p /usr/share/polkit-1/actions
cat <<EOF > /usr/share/polkit-1/actions/com.shellyorg.shelly.policy
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
    <vendor>Shelly</vendor>
    <vendor_url>https://github.com/Seafoam-Labs/Shelly-ALPM</vendor_url>
    <action id="com.shellyorg.shelly.pkexec.cli">
        <description>Run Shelly CLI as administrator</description>
        <message>Authentication is required to run privileged Shelly CLI operations.</message>
        <icon_name>shelly-shell</icon_name>
        <defaults>
            <allow_any>auth_admin</allow_any>
            <allow_inactive>auth_admin</allow_inactive>
            <allow_active>auth_admin_keep</allow_active>
        </defaults>
        <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/shelly</annotate>
    </action>
</policyconfig>
EOF
chmod 644 /usr/share/polkit-1/actions/com.shellyorg.shelly.policy

# Clean up publish directory (optional - comment out to keep build artifacts)
echo "Cleaning up build artifacts..."
rm -rf "$SCRIPT_DIR/publish"

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "You can now:"
echo "  - Run the GUI: shelly-ui"
echo "  - Run the CLI: shelly"
echo "  - Notification Service: shelly-notifications"
echo "  - Find Shelly in your application menu"
echo ""
