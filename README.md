# NixOS TPM Host Key

An SSH host key for stateless NixOS hosts, derived from the TPM at every boot. Nothing secret is stored anywhere.

## How It Works

A TPM can recreate a key instead of storing it. Give it the same template (key type, attributes, label) and it derives the same key from a seed that was burned into the chip at manufacture.

1. `tpm2_createprimary -C e -G hmac`: the TPM derives an HMAC key **K** from its endorsement seed and a fixed template. K never leaves the chip.
2. `tpm2_hmac`: the TPM returns **X** = HMAC-SHA256(K, `"nix-config tpm-host-key v1"`). This is the same 32 bytes on every boot.
3. SHA-256(X) becomes an ed25519 seed. The OpenSSH key is written to `/run/tpm-host-key/ssh_host_ed25519_key` (tmpfs, 0600) during activation, before [agenix](https://github.com/ryantm/agenix) runs.

### Limitations

- The key is bound to the TPM. On firmware TPMs (AMD fTPM, Intel PTT), that means the CPU. Replacing either gives a new key, so the host's secrets must be rekeyed.
- Anyone who can boot code on the board can derive the key, as with any key a machine unlocks without user input.

## Documentation

See the [documentation](./docs/tpm-host-key.md).
