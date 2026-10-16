# Development environment

- Primary development is done on Devario, not Arch Linux.
- Prefer Devario tooling and workflows, including Shelly, for development, packaging, and validation. Do not assume Arch-specific tools are installed or required; use them when the task explicitly targets Arch or no suitable Devario equivalent exists.

# Packaging preferences

- Use Shelly to generate `.SRCINFO` from PKGBUILDs. Shelly is available in this environment even when `makepkg` is not.
- Use `shelly build <PKGBUILD-path> --makesrcinfo`, which emits SRCINFO on standard output. Capture the output and replace the intended `.SRCINFO` only after the command succeeds.
- Prefer Shelly's metadata generator over manually reconstructing `.SRCINFO`. Preserve the intended `SHELLY_LIBALPM` setting; the root PKGBUILD defaults to `true`.
