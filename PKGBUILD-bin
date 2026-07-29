# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly-bin
pkgname=('shelly-bin' 'shelly-flatpak-backend-bin')
pkgver=3.0.0+9
pkgrel=1
arch=('x86_64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
source=(
    "Shelly-ALPM-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-ALPM-linux-x64.tar.gz"
    "Shelly-Flatpak-Backend-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-Flatpak-Backend-linux-x64.tar.gz"
)

sha256sums=('1c696140104d7f51eaa5fe6488b32f4a0d441944c1f127ad9507399b156f8ce6'
            '46907ce81348430aefbb27cd865cc2470aba9087d352a5f1c3cfb9d576f34f16')

package_shelly-bin() {
  pkgdesc="Shelly: A Modern Arch Package Manager (prebuilt binary)"
  provides=('shelly')
  conflicts=('shelly' 'shelly-git')
  depends=(
      'pacman'
      'gtk4'
      'glib2'
      'sudo'
      'tar'
      'bash'
      'git'
      'hicolor-icon-theme'
      'dbus'
      'glibc'
      'libarchive'
      'dconf'
      'gnupg'
      'zstd'
      'json-glib'
  )
  optdepends=(
      'fish: Fish shell completions'
      'zsh: Zsh shell completions'
      'libstarfish: dependency viewer for arch packages'
      'shelly-flatpak-backend-bin: Flatpak package management support'
      'fuse2: run AppImages that require FUSE 2'
  )

  # Install Shelly.Gtk binary
  install -Dm755 "$srcdir/shelly-ui" "$pkgdir/usr/bin/shelly-ui"

  # Install Shelly-Notifications binary
  install -Dm755 "$srcdir/shelly-notifications" "$pkgdir/usr/bin/shelly-notifications"

  # Install Shelly.Cli binary
  install -Dm755 "$srcdir/shelly" "$pkgdir/usr/bin/shelly"

  # Install Shelly.Key binary
  install -Dm755 "$srcdir/shelly-key" "$pkgdir/usr/bin/shelly-key"

  # Install desktop entry
  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly.desktop"
[Desktop Entry]
Name=Shelly
Comment=A Modern Arch Package Manager
Exec=/usr/bin/shelly-ui %u
Icon=shelly
Type=Application
Categories=System;Utility;
Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
MimeType=x-scheme-handler/appstream;x-scheme-handler/flatpak+https;
Terminal=false
X-GNOME-UsesNotifications=true
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

  # Install desktop entry for notification service
  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly-notifications.desktop"
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

  # Ensure the polkit directory exists
  install -m0755 -d "${pkgdir}"/usr/share/polkit-1/actions

  # Install Polkit policy for privileged Shelly CLI execution via pkexec
  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/polkit-1/actions/com.shellyorg.shelly.policy"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
  <vendor>Shelly</vendor>
  <vendor_url>https://github.com/Seafoam-Labs/Shelly-ALPM</vendor_url>
  <action id="com.shellyorg.shelly.pkexec.cli">
    <description>Run Shelly CLI as administrator</description>
    <message>Run Shelly CLI with administrator privileges.</message>
    <icon_name>shelly</icon_name>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/shelly</annotate>
  </action>
</policyconfig>
EOF

  # Install icon
  install -Dm644 "$srcdir/shellylogo.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"

  install -Dm644 "$srcdir/shellylogo-tray.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-tray.png"
  install -Dm644 "$srcdir/shellylogo-update.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-update.png"

  # Install fish shell completions
  install -Dm644 "$srcdir/shelly.fish" "$pkgdir/usr/share/fish/vendor_completions.d/shelly.fish"

  # Install zsh shell completions
  install -Dm644 "$srcdir/_shelly" "$pkgdir/usr/share/zsh/site-functions/_shelly"

  # Install translations
if [ -d "$srcdir/locale" ] && [ -n "$(ls -A "$srcdir/locale" 2>/dev/null)" ]; then
    install -d "$pkgdir/usr/share/locale"
    cp -r "$srcdir/locale/."/* "$pkgdir/usr/share/locale/" 2>/dev/null || true
fi

  # Install Flatpak integration script
  cat <<'SCRIPT' | install -Dm755 /dev/stdin "$pkgdir/usr/bin/shelly-flatpak-integrate"
#!/bin/bash
# Adds "Manage in Shelly" right-click action to all Flatpak .desktop files
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
        app_id="${filename%.desktop}"
        dest="$LOCAL_APPS_DIR/$filename"

        # Copy if override doesn't exist yet
        [ -f "$dest" ] || cp "$desktop_file" "$dest"

        # Skip if already patched
        grep -q "ShellyManage" "$dest" && continue

        # Add action to existing Actions= line or insert one
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
}

package_shelly-flatpak-backend-bin() {
  pkgdesc="Optional native Flatpak backend for Shelly (prebuilt binary)"
  depends=("shelly-bin=${pkgver}-${pkgrel}" 'flatpak')
  provides=("shelly-flatpak-backend=${pkgver}")
  conflicts=('shelly-flatpak-backend' 'shelly-flatpak-backend-git')

  install -Dm755 \
    "$srcdir/libshelly-flatpak-backend.so.1.0.0" \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
  ln -s libshelly-flatpak-backend.so.1.0.0 \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1"
}
