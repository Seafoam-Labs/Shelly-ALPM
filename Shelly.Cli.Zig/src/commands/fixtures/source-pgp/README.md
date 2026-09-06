These public test fixtures are copied from the existing source-PGP fixtures in
`Shelly.PackageManager/src/aur/builder/builder_test.zig`:

- `public.asc`: public key `2E37DFCC9287C8A2F84B2519241A5B24548FAC70`.
- `payload.txt`: the decompressed `source_pgp_payload_gzip_base64` fixture.
- `payload.sig`: the detached `source_pgp_signature_base64` fixture.

They contain no private keys and require no network access. CLI tests import the
public key only into disposable test keyrings.
