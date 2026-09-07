# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly-git
pkgname=('shelly-git' 'shelly-flatpak-backend-git')
pkgver=3.1.3
pkgrel=1
arch=('x86_64' 'aarch64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
makedepends=('git' 'pkgconf' 'gtk4' 'zig>=0.16' 'clang' 'gettext' 'flatpak' 'ripgrep' 'go-md2man')

source=("${pkgname}::git+https://github.com/Seafoam-Labs/Shelly-ALPM.git#branch=development"
        'shellybuild.conf'
        'com.shellyorg.shelly.desktop'
        'com.shellyorg.shelly-notifications.desktop'
        'shelly-flatpak-integrate')

sha256sums=('SKIP'
            '0aff9177498bd94e90c937076d15ac76116c628ec3504a7c1b8c9ea086336ca6'
            '2cdefd69e5e1a2ecaa9a787ef04137af16d55690361034420f4dfcbb575e8627'
            '05f39f65a0f0797ea8a45b10cb693a197908aec298b2a17422a6d942ad1dee36'
            'da6ed2f71966aef9cc20f7dcd3a5aa87afd3d57d2fccebfe71be62e4d9ae64d5')

pkgver() {
  cd "${srcdir}/${pkgname}"

  printf '3.1.3r%s.g%s' \
    "$(git rev-list --count HEAD)" \
    "$(git rev-parse --short=7 HEAD)"
}

build() {
  cd "$srcdir/${pkgname}"

  (cd Shelly.Flatpak.Backend && zig build --verbose \
    --prefix "${srcdir}/${pkgbase}/out-flatpak-backend" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe)

  (cd Shelly.Ui.Gtk && zig build --verbose \
    --prefix "${srcdir}/${pkgname}/out" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dflatpak-backend-package=shelly-flatpak-backend-git \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe)

  (cd Shelly.Cli.Zig && zig build --verbose \
    --prefix "${srcdir}/${pkgname}/out-cli" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)

  (cd Shelly.Key && zig build --verbose \
    --prefix "${srcdir}/${pkgname}/out-key" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)

    (cd Shelly.Notifications.Zig && zig build --verbose \
    --prefix "${srcdir}/${pkgbase}/out-notifications" \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)


  ./out-cli/bin/shelly utility --completions bash > shelly.bash
  ./out-cli/bin/shelly utility --completions fish > shelly.fish
  ./out-cli/bin/shelly utility --completions zsh  > _shelly

  ./out-cli/bin/shelly utility --docs | go-md2man > shelly.1
  sed -i "s|^\\.TH .*|.TH \"SHELLY\" \"1\" \"\" \"Shelly ${pkgver}\" \"Shelly CLI Manual\"|" shelly.1
  printf '\n.SH AUTHORS\nSeafoam Labs.\n' >> shelly.1

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
  cd "$srcdir/${pkgbase}"

  (cd Shelly.Flatpak.Backend && zig build test abi-test integration-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.PackageManager && zig build flatpak-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.Cli.Zig && zig build test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
}

package_shelly-git() {
  pkgdesc="Shelly: A Modern Arch Package Manager (git version)"
  provides=('shelly')
  conflicts=('shelly' 'shelly-bin')
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
      'fish: Fish shell completions'
      'zsh: Zsh shell completions'
      'libstarfish: dependency viewer for arch packages'
      'shelly-flatpak-backend-git: Flatpak package management support'
      'util-linux: isolate fresh-root provisioning for --isolated builds'
      'fuse2: run AppImages that require FUSE 2'
  )

  cd "$srcdir/${pkgname}"
  install -Dm755 out-notifications/bin/shelly-notifications "$pkgdir/usr/bin/shelly-notifications"
  install -Dm755 out/bin/Shelly_Ui_Gtk "$pkgdir/usr/bin/shelly-ui"
  install -Dm755 out-cli/bin/shelly "$pkgdir/usr/bin/shelly"
  install -Dm755 out-key/bin/shelly-key "$pkgdir/usr/bin/shelly-key"
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
  install -Dm644 assets/shellylogo.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"
  install -Dm644 assets/shelly-updates-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-updates-symbolic.svg"
  install -Dm644 assets/shelly-shell-symbolic.svg "$pkgdir/usr/share/icons/hicolor/symbolic/apps/shelly-shell-symbolic.svg"

  install -Dm644 assets/shellylogo-tray.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-tray.png"
  install -Dm644 assets/shellylogo-update.png "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-update.png"

  install -Dm644 shelly.bash "$pkgdir/usr/share/bash-completion/completions/shelly"
  install -Dm644 shelly.fish "$pkgdir/usr/share/fish/vendor_completions.d/shelly.fish"
  install -Dm644 _shelly "$pkgdir/usr/share/zsh/site-functions/_shelly"

  # Install man page
  install -Dm644 shelly.1 "$pkgdir/usr/share/man/man1/shelly.1"

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
  install -Dm755 "$srcdir/shelly-flatpak-integrate" \
    "$pkgdir/usr/bin/shelly-flatpak-integrate"
}

package_shelly-flatpak-backend-git() {
  pkgdesc="Optional native Flatpak backend for Shelly (git version)"
  depends=("shelly-git=${pkgver}-${pkgrel}" 'flatpak')
  provides=("shelly-flatpak-backend=${pkgver}")
  conflicts=('shelly-flatpak-backend' 'shelly-flatpak-backend-bin')

  cd "$srcdir/${pkgbase}"
  install -Dm755 \
    out-flatpak-backend/lib/libshelly-flatpak-backend.so.1.0.0 \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
  ln -s libshelly-flatpak-backend.so.1.0.0 \
    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1"
}
