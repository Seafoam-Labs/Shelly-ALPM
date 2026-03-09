# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgname=shelly
pkgver=1.5.6
pkgrel=1
pkgdesc="Shelly: A Modern Arch Package Manager"
arch=('x86_64')
url="https://github.com/ZoeyErinBauer/Shelly-ALPM"
license=('GPL-3.0-only')
provides=('shelly')
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
    'glib2'
)
optdepends=(
    'flatpak:  For supporting flatpak implementation.'
)
makedepends=('dotnet-sdk-10.0')

# Source tarball from GitHub release
source=("${pkgname}-${pkgver}.tar.gz::https://github.com/ZoeyErinBauer/Shelly-ALPM/archive/v${pkgver}.tar.gz")

sha256sums=('a00b159faa548a37663a552ab24159788cd2201ce7c717218e21567744b6a3a1')

build() {
  cd "$srcdir/Shelly-ALPM-${pkgver}"

  dotnet publish Shelly-CLI/Shelly-CLI.csproj -c Release -o out-cli --nologo -p:InstructionSet=${INSTRUCTIONS:=x86-64}
  dotnet publish Shelly.Gtk/Shelly.Gtk.csproj -c Release -r linux-x64 -o out --nologo -p:InstructionSet=${INSTRUCTIONS:=x86-64}
  dotnet publish Shelly-Notifications/Shelly-Notifications.csproj -c Release -r linux-x64 -o out-notify --nologo -p:InstructionSet=${INSTRUCTIONS:=x86-64-v3}
}

package() {
  cd "$srcdir/Shelly-ALPM-${pkgver}"

  # Install Shelly.Gtk binary
  install -Dm755 out/shelly-ui "$pkgdir/usr/bin/shelly-ui"

  # Install Shelly-Notifications binary
  install -Dm755 out-notify/Shelly-Notifications "$pkgdir/usr/bin/shelly-notifications"

  # Install Shelly-CLI binary
  install -Dm755 out-cli/shelly "$pkgdir/usr/bin/shelly"

  # Install desktop entry
  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/shelly.desktop"
[Desktop Entry]
Name=Shelly
Comment=A Modern Arch Package Manager
Exec=/usr/bin/shelly-ui
Icon=shelly
Type=Application
Categories=System;Utility;
Terminal=false
EOF

  # Install icon
  install -Dm644 Shelly.Gtk/Assets/shellylogo.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"
  install -Dm644 Shelly.Gtk/Assets/svg/flatpak-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/flatpak-symbolic.svg"
  install -Dm644 Shelly.Gtk/Assets//svg/arch-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/arch-symbolic.svg"
}
