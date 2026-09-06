# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>

pkgbase=shelly-cli
pkgname=('shelly-cli' 'shelly-cli-flatpak-backend')
pkgver=3.1.3
pkgrel=1
arch=('x86_64')
url='https://github.com/Seafoam-Labs/Shelly-ALPM'
license=('GPL-3.0-only')
makedepends=(
  'git'
  'pkgconf'
  'zig>=0.16.0'
  'flatpak'
  'ripgrep'
  'go-md2man'
)
source=("${pkgname}::git+https://github.com/Seafoam-Labs/Shelly-ALPM.git#branch=development"
        'shellybuild.conf')
sha256sums=('SKIP'
            '0aff9177498bd94e90c937076d15ac76116c628ec3504a7c1b8c9ea086336ca6')
conflicts=('shelly' 'shelly-git' 'shelly-bin')

pkgver() {
  cd "${srcdir}/${pkgname}"

  printf '3.1.3r%s.g%s' \
    "$(git rev-list --count HEAD)" \
    "$(git rev-parse --short=7 HEAD)"
}

build() {
  cd "${srcdir}/${pkgbase}"

  (cd Shelly.Flatpak.Backend && zig build --verbose \
    --prefix "${srcdir}/zig-out-flatpak-backend" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSafe)

  (cd Shelly.Cli.Zig && zig build --verbose \
    --prefix "${srcdir}/zig-out" \
    -Dcpu=baseline \
    -Doptimize=ReleaseSmall)

  for shell in bash fish zsh; do
    "${srcdir}/zig-out/bin/shelly" utility --completions "${shell}" \
      > "${srcdir}/shelly.${shell}"
  done

  "${srcdir}/zig-out/bin/shelly" utility --docs | go-md2man > "${srcdir}/shelly.1"
  sed -i "s|^\\.TH .*|.TH \"SHELLY-BETA\" \"1\" \"\" \"Shelly CLI Beta ${pkgver}\" \"Shelly CLI Manual\"|" "${srcdir}/shelly.1"
  printf '\n.SH AUTHORS\nSeafoam Labs.\n' >> "${srcdir}/shelly.1"

  sed -i \
    -e 's/_shelly/_shelly_beta/g' \
    -e 's/complete -F _shelly_beta shelly/complete -F _shelly_beta shelly-beta/' \
    "${srcdir}/shelly.bash"
  sed -i 's/complete -c shelly/complete -c shelly-beta/g' \
    "${srcdir}/shelly.fish"
  sed -i \
    -e 's/^#compdef shelly$/#compdef shelly-beta/' \
    -e 's/_shelly/_shelly-beta/g' \
    "${srcdir}/shelly.zsh"
}

check() {
  cd "${srcdir}/${pkgbase}"

  (cd Shelly.Flatpak.Backend && zig build test abi-test integration-test)
  (cd Shelly.PackageManager && zig build flatpak-test)
  (cd Shelly.Cli.Zig && zig build test)
}

package_shelly-cli() {
  pkgdesc='Native Shelly package-manager CLI beta'
  provides=('shelly-beta')
  backup=('etc/shellybuild.conf')
  depends=(
    'diffutils'
    'git'
    'glibc'
    'libarchive'
    'pacman'
    'sudo'
  )
  optdepends=(
    'base-devel: build and install AUR packages'
    'devtools: build AUR packages in a clean chroot'
    'desktop-file-utils: update AppImage desktop entries'
    'fuse2: run AppImages that require FUSE 2'
    'shelly-cli-flatpak-backend: Flatpak package management support'
    'gtk-update-icon-cache: update AppImage icons'
    'opendoas: alternative privilege elevator to sudo'
    'plocate: locate-based pacfile discovery'
    'util-linux: isolate fresh-root provisioning for --isolated builds'
    'vim: default visual pacfile diff viewer'
  )

  cd "${srcdir}/${pkgbase}"

  install -Dm755 "${srcdir}/zig-out/bin/shelly" \
    "${pkgdir}/usr/bin/shelly"
  install -Dm644 "${srcdir}/shellybuild.conf" \
    "${pkgdir}/etc/shellybuild.conf"
  install -Dm644 "${srcdir}/shelly.bash" \
    "${pkgdir}/usr/share/bash-completion/completions/shelly-beta"
  install -Dm644 "${srcdir}/shelly.fish" \
    "${pkgdir}/usr/share/fish/vendor_completions.d/shelly-beta.fish"
  install -Dm644 "${srcdir}/shelly.zsh" \
    "${pkgdir}/usr/share/zsh/site-functions/_shelly-beta"
  install -Dm644 "${srcdir}/shelly.1" \
    "${pkgdir}/usr/share/man/man1/shelly-beta.1"
  install -Dm644 LICENSE \
    "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}

package_shelly-cli-flatpak-backend() {
  pkgdesc='Optional native Flatpak backend for the Shelly CLI beta'
  depends=("shelly-cli=${pkgver}-${pkgrel}" 'flatpak')
  provides=("shelly-flatpak-backend=${pkgver}")
  conflicts=(
    'shelly-flatpak-backend'
    'shelly-flatpak-backend-git'
    'shelly-flatpak-backend-bin'
  )
  optdepends=()

  install -Dm755 \
    "${srcdir}/zig-out-flatpak-backend/lib/libshelly-flatpak-backend.so.1.0.0" \
    "${pkgdir}/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
  ln -s libshelly-flatpak-backend.so.1.0.0 \
    "${pkgdir}/usr/lib/shelly/libshelly-flatpak-backend.so.1"
}
