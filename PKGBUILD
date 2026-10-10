# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
# Maintainer: Caroline Snyder <hirpeng@gmail.com>
pkgbase=shelly
pkgname=('shelly' 'shelly-flatpak-backend')
pkgver=3.1.6
pkgrel=2
arch=('x86_64' 'aarch64')
url="https://github.com/Seafoam-Labs/Shelly-ALPM"
license=('GPL-3.0-only')
makedepends=('libarchive' 'curl' 'sqlite' 'gnupg' 'git' 'pkgconf' 'gtk4' 'zig>=0.16' 'clang' 'gettext' 'flatpak' 'ripgrep' 'go-md2man')

# Keep package metadata tied to the compiled native backend variant.
_shelly_libalpm=${SHELLY_LIBALPM:-true}
case $_shelly_libalpm in
  true) _shelly_native_depends=('pacman'); _shelly_native_optdepends=() ;;
  false) _shelly_native_depends=(); _shelly_native_optdepends=('pacman: package-owner lookup for pacfile merging') ;;
  *) printf 'SHELLY_LIBALPM must be true or false\n' >&2; return 1 ;;
esac
makedepends+=('binutils' "${_shelly_native_depends[@]}")

# Source tarball from GitHub release
source=("${pkgname}-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/archive/v${pkgver}.tar.gz"
        'shellybuild.conf'
        'com.shellyorg.shelly.desktop'
        'com.shellyorg.shelly-notifications.desktop'
        'shelly-flatpak-integrate')

sha256sums=('fa1e587a69b9d6e63e6835696e2d696f880d6120a023f5c922e260fc023e70af'
            '69a353bf17b5a556203f9a517608532dd1eb5e167a7218dbd9ad7c1dad86580a'
            'aa00144868ee38674a1f3eaffd329a04767309449b3260511da1cdfc09054f7e'
            '7dd7983aab6b2e006bd17e9ced23a7b83d6fe636e611143f7c9eaddd4ffee816'
            '3c64a1a9c6e05ac92f809bfece645a4a1f5b3363ea47386efa226b3fdb78af45')
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

  (cd Shelly.Cli.Zig && zig build -Dlibalpm="${_shelly_libalpm}" --verbose \
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
  cd "$srcdir/${_source_dir}"

  (cd Shelly.Flatpak.Backend && zig build test abi-test integration-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.PackageManager && zig build -Dlibalpm="${_shelly_libalpm}" flatpak-test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
  (cd Shelly.Cli.Zig && zig build -Dlibalpm="${_shelly_libalpm}" test \
    --cache-dir "${srcdir}/zig-cache" \
    --global-cache-dir "${srcdir}/zig-global-cache")
}

package_shelly() {
  pkgdesc="Shelly: A Modern Arch Package Manager"
  provides=('shelly')
  conflicts=('shelly-git' 'shelly-bin')
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
      'shelly-flatpak-backend: Flatpak package management support'
      'util-linux: isolate fresh-root provisioning for --isolated builds'
      'fuse2: run AppImages that require FUSE 2'
  )

  cd "$srcdir/${_source_dir}"
  install -Dm755 out-notifications/bin/shelly-notifications "$pkgdir/usr/bin/shelly-notifications"
  install -Dm755 out/bin/Shelly_Ui_Gtk "$pkgdir/usr/bin/shelly-ui"
  install -Dm755 out-cli/bin/shelly "$pkgdir/usr/bin/shelly"
  local shelly_dynamic
  shelly_dynamic=$(LC_ALL=C readelf -d "$pkgdir/usr/bin/shelly") || return 1
  if [[ $_shelly_libalpm == true && $shelly_dynamic != *libalpm.so* ]] ||
     [[ $_shelly_libalpm == false && $shelly_dynamic == *libalpm.so* ]]; then
    printf 'Shelly binary does not match SHELLY_LIBALPM package metadata\n' >&2
    return 1
  fi
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

  # Install shell completions
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
