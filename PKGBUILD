# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly
pkgname=('shelly' 'shelly-flatpak-backend')
pkgver=3.0.3
pkgrel=1
arch=('x86_64' 'aarch64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
makedepends=('git' 'pkgconf' 'gtk4' 'zig>=0.16' 'clang' 'gettext' 'flatpak' 'ripgrep')

# Source tarball from GitHub release
source=("${pkgname}-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/archive/v${pkgver}.tar.gz")

sha256sums=('80ee02aeabf10e97d8a33856464167c8001fbc1201656e5074e7c8f057d5b408')
# GitHub replaces "+" with "-" in archive top-level directory names.
_source_dir="Shelly-ALPM-${pkgver//+/-}"

build() {
  cd "$srcdir/${_source_dir}"

  (cd Shelly.Flatpak.Backend && zig build --verbose \
    --prefix "${srcdir}/${_source_dir}/out-flatpak-backend" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe)

  (cd Shelly.Ui.Gtk && zig build --verbose \
    --prefix "${srcdir}/${_source_dir}/out" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dflatpak-backend-package=shelly-flatpak-backend \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe)

  (cd Shelly.Cli.Zig && zig build --verbose \
    --prefix "${srcdir}/${_source_dir}/out-cli" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)

  (cd Shelly.Key && zig build --verbose \
    --prefix "${srcdir}/${_source_dir}/out-key" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)

   (cd Shelly.Notifications.Zig && zig build --verbose \
     --prefix "${srcdir}/${_source_dir}/out-notifications" \
     --cache-dir "${srcdir}/zig-cache" \
     --global-cache-dir "${srcdir}/zig-global-cache" \
     -Dcpu=baseline \
     -Doptimize=ReleaseSmall)

  ./out-cli/bin/shelly utility --completions bash > shelly.bash
  ./out-cli/bin/shelly utility --completions fish > shelly.fish
  ./out-cli/bin/shelly utility --completions zsh  > _shelly

  for po_file in Shelly.Ui.Gtk/po/*.po; do
    [ -f "$po_file" ] || continue
    lang=$(basename "$po_file" .po)
    msgfmt "$po_file" -o "shelly-ui-${lang}.mo"
  done

  for po_file in Shelly.Notifications.Zig/po/*.po; do
    [ -f "$po_file" ] || continue
    lang=$(basename "$po_file" .po)
    msgfmt "$po_file" -o "shelly-notifications-${lang}.mo"
  done
}

check() {
  cd "$srcdir/${_source_dir}"

  (cd Shelly.Flatpak.Backend && zig build test abi-test integration-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.PackageManager && zig build flatpak-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.Cli.Zig && zig build test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  scripts/check-flatpak-separation.sh \
    out-cli/bin/shelly \
    out-flatpak-backend/lib/libshelly-flatpak-backend.so.1
}

package_shelly() {
  pkgdesc="Shelly: A Modern Arch Package Manager"
  provides=('shelly')
  conflicts=('shelly-git' 'shelly-bin')
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
      'shelly-flatpak-backend: Flatpak package management support'
      'fuse2: run AppImages that require FUSE 2'
  )

  cd "$srcdir/${_source_dir}"
  install -Dm755 out-notifications/bin/shelly-notifications "$pkgdir/usr/bin/shelly-notifications"
  install -Dm755 out/bin/Shelly_Ui_Gtk "$pkgdir/usr/bin/shelly-ui"
  install -Dm755 out-cli/bin/shelly "$pkgdir/usr/bin/shelly"
  install -Dm755 out-key/bin/shelly-key "$pkgdir/usr/bin/shelly-key"

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
  install -Dm644 assets/shellylogo.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"
  install -Dm644 assets/shelly-updates-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-updates-symbolic.svg"
  install -Dm644 assets/shelly-shell-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-shell-symbolic.svg"

  install -Dm644 assets/shellylogo-tray.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-tray.png"
  install -Dm644 assets/shellylogo-update.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-update.png"

  install -Dm644 shelly.bash "$pkgdir/usr/share/bash-completion/completions/shelly"
  install -Dm644 shelly.fish "$pkgdir/usr/share/fish/vendor_completions.d/shelly.fish"
  install -Dm644 _shelly "$pkgdir/usr/share/zsh/site-functions/_shelly"

  # Install translations
  for mo_file in shelly-ui-*.mo; do
    if [ -f "$mo_file" ]; then
      lang=$(echo "$mo_file" | sed 's/shelly-ui-\(.*\)\.mo/\1/')
      install -Dm644 "$mo_file" "$pkgdir/usr/share/locale/$lang/LC_MESSAGES/shelly-ui.mo"
    fi
  done

  # Install tray service translations
    for mo_file in shelly-notifications-*.mo; do
      if [ -f "$mo_file" ]; then
        lang=$(echo "$mo_file" | sed 's/shelly-notifications-\(.*\)\.mo/\1/')
        install -Dm644 "$mo_file" "$pkgdir/usr/share/locale/$lang/LC_MESSAGES/shelly-notifications.mo"
      fi
    done

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

package_shelly-flatpak-backend() {
  pkgdesc="Optional native Flatpak backend for Shelly"
  depends=("shelly=${pkgver}" 'flatpak')
  provides=("shelly-flatpak-backend=${pkgver}")
  conflicts=('shelly-flatpak-backend-git' 'shelly-flatpak-backend-bin')

  cd "$srcdir/${_source_dir}"
  install -Dm755 \
    out-flatpak-backend/lib/libshelly-flatpak-backend.so.1.0.0 \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
  ln -s libshelly-flatpak-backend.so.1.0.0 \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1"
}
