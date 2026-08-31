# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly-bin
pkgname=('shelly-bin' 'shelly-flatpak-backend-bin')
pkgver=3.1.2
pkgrel=1
arch=('x86_64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
makedepends=('go-md2man')
source=(
    "Shelly-ALPM-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-ALPM-linux-x64.tar.gz"
    "Shelly-Flatpak-Backend-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-Flatpak-Backend-linux-x64.tar.gz"
    'shellybuild.conf'
    'com.shellyorg.shelly.desktop'
    'com.shellyorg.shelly-notifications.desktop'
    'shelly-flatpak-integrate'
)

sha256sums=('8501bb9e7758efe505990f247004c9cb2c014fe625c911c55b7fca0ba8d8af9c'
            'fa0cf740f0ff323fa30fb9028c7b283ade31e9b9587a0337b7c1694903d94496'
            '0aff9177498bd94e90c937076d15ac76116c628ec3504a7c1b8c9ea086336ca6'
            '2cdefd69e5e1a2ecaa9a787ef04137af16d55690361034420f4dfcbb575e8627'
            '05f39f65a0f0797ea8a45b10cb693a197908aec298b2a17422a6d942ad1dee36'
            'da6ed2f71966aef9cc20f7dcd3a5aa87afd3d57d2fccebfe71be62e4d9ae64d5')

package_shelly-bin() {
  pkgdesc="Shelly: A Modern Arch Package Manager (prebuilt binary)"
  provides=('shelly')
  conflicts=('shelly' 'shelly-git')
  backup=('etc/shellybuild.conf')
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
      'arch-install-scripts: provision fresh roots for --isolated builds'
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
  install -Dm644 "$srcdir/shellybuild.conf" "$pkgdir/etc/shellybuild.conf"

  # Install desktop entries
  install -Dm644 "$srcdir/com.shellyorg.shelly.desktop" \
    "$pkgdir/usr/share/applications/com.shellyorg.shelly.desktop"
  install -Dm644 "$srcdir/com.shellyorg.shelly-notifications.desktop" \
    "$pkgdir/usr/share/applications/com.shellyorg.shelly-notifications.desktop"

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

  # Install man page
  "$srcdir/shelly" utility --docs | go-md2man > "$srcdir/shelly.1"
  sed -i "s|^\\.TH .*|.TH \"SHELLY\" \"1\" \"\" \"Shelly ${pkgver}\" \"Shelly CLI Manual\"|" "$srcdir/shelly.1"
  printf '\n.SH AUTHORS\nSeafoam Labs.\n' >> "$srcdir/shelly.1"
  install -Dm644 "$srcdir/shelly.1" "$pkgdir/usr/share/man/man1/shelly.1"

  # Install translations
if [ -d "$srcdir/locale" ] && [ -n "$(ls -A "$srcdir/locale" 2>/dev/null)" ]; then
    install -d "$pkgdir/usr/share/locale"
    cp -r "$srcdir/locale/."/* "$pkgdir/usr/share/locale/" 2>/dev/null || true
fi

  # Install Flatpak integration script
  install -Dm755 "$srcdir/shelly-flatpak-integrate" \
    "$pkgdir/usr/bin/shelly-flatpak-integrate"
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
