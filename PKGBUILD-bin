# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly-bin
pkgname=('shelly-bin' 'shelly-flatpak-backend-bin')
pkgver=3.3.0
pkgrel=1
arch=('x86_64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
makedepends=('go-md2man' 'binutils')
# Declare the expected release variant and verify it against the shipped CLI.
_shelly_libalpm=${SHELLY_LIBALPM:-true}
case $_shelly_libalpm in
  true) _shelly_native_depends=('pacman'); _shelly_native_optdepends=() ;;
  false) _shelly_native_depends=(); _shelly_native_optdepends=('pacman: package-owner lookup for pacfile merging') ;;
  *) printf 'SHELLY_LIBALPM must be true or false\n' >&2; return 1 ;;
esac

# The release tarball bundles only PNG icons; fetch the symbolic tray icons
# used by shelly-notifications (UseSymbolicTray) from the release tag.
source=(
    "Shelly-ALPM-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-ALPM-linux-x64.tar.gz"
    "Shelly-Flatpak-Backend-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-Flatpak-Backend-linux-x64.tar.gz"
    "shelly-updates-symbolic-${pkgver}.svg::https://raw.githubusercontent.com/Seafoam-Labs/Shelly-ALPM/v${pkgver}/assets/shelly-updates-symbolic.svg"
    "shelly-shell-symbolic-${pkgver}.svg::https://raw.githubusercontent.com/Seafoam-Labs/Shelly-ALPM/v${pkgver}/assets/shelly-shell-symbolic.svg"
    'shellybuild.conf'
    'com.shellyorg.shelly.desktop'
    'com.shellyorg.shelly-notifications.desktop'
    'shelly-flatpak-integrate'
)

sha256sums=('ac39c6d64c8ee48b395827cf090086179561271b5a4251c3c35b87634ed34983'
            '706277d1c32f897d3695e0e8d8c7df24e7bb3d31f0b7779ebf301922a7ae6853'
            'cfec9274ece30407404b3c41187c465c68f1a6017394ac31c0be937d06f8a850'
            '27eb0cf269296254f45c68c88a27b0e43817bb6107db8e7edb87ea030730bf25'
            '4126da205e91a3ba3b15453c2aeade92f67e16e3386a52aae32fbd3f2e4af9cc'
            '4b7cb0e42eb322de9eb616d22ca05823f91d178db5b8b67497d497ed495aca9c'
            'cf0dc0a6d1865b9010054b36941e7bf4d445c3e7549219889f07ab08283c5c0f'
            '07bca40395c180578450c523ea052b036aa8197d8a871efcce55f937c101c323')

package_shelly-bin() {
  pkgdesc="Shelly: A Modern Arch Package Manager (prebuilt binary)"
  provides=('shelly')
  conflicts=('shelly' 'shelly-git')
  backup=('etc/shellybuild.conf')
  depends=(
      "${_shelly_native_depends[@]}"
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
      'curl'
      'sqlite'
      'dconf'
      'gnupg'
      'zstd'
      'json-glib'
  )
  optdepends=(
      "${_shelly_native_optdepends[@]}"
      'fish: Fish shell completions'
      'zsh: Zsh shell completions'
      'libstarfish: dependency viewer for arch packages'
      'shelly-flatpak-backend-bin: Flatpak package management support'
      'util-linux: isolate fresh-root provisioning for --isolated builds'
      'fuse2: run AppImages that require FUSE 2'
  )

  local shelly_dynamic
  shelly_dynamic=$(LC_ALL=C readelf -d "$srcdir/shelly") || return 1
  if [[ $shelly_dynamic != *'Shared library: [libsqlite3.so.0]'* ]]; then
    printf 'Shelly CLI must directly depend on libsqlite3.so.0 (#2059)\n' >&2
    return 1
  fi
  if [[ $_shelly_libalpm == true && $shelly_dynamic != *libalpm.so* ]] ||
     [[ $_shelly_libalpm == false && $shelly_dynamic == *libalpm.so* ]]; then
    printf 'Shelly binary does not match SHELLY_LIBALPM package metadata\n' >&2
    return 1
  fi

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
  install -Dm644 "$srcdir/shelly-updates-symbolic-${pkgver}.svg" "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-updates-symbolic.svg"
  install -Dm644 "$srcdir/shelly-shell-symbolic-${pkgver}.svg" "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-shell-symbolic.svg"

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
