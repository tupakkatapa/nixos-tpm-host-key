# NixOS TPM Host Key

An SSH host key for stateless NixOS hosts, derived from the TPM at every boot, stored nowhere. Optionally also bound to you by a security key and PIN.

## Why Use TPM Host Key?

*"Something the machine has, something you have, something you know."*

- **Something the machine has:** the TPM recreates the same secret from a seed burned into the chip. The key can only exist on this board.

- **Something you have** (optional): a security key, such as a YubiKey, adds a second secret from its own chip. The key can only exist when you are there.

- **Something you know** (optional): the security key gives up its secret only after its PIN and a touch. Holding it is not enough.

- **Stored nowhere:** both halves are recreated at boot and combined in RAM. No file, image, partition or sealed blob holds the key, so there is nothing to back up, leak or wipe. A stateless host stays stateless.

With a security key, a stolen laptop gives the thief the machine, but not you. A stolen security key is useless without its PIN, and even with it, it still needs the board. The one key serves as the sshd host key and, with [agenix](https://github.com/ryantm/agenix), as the identity that decrypts the host's secrets.

## How It Works

A TPM can recreate a key instead of storing it: the same template always yields the same key.

1. `tpm2_createprimary -C e -G hmac`: the TPM derives an HMAC key **K** from its endorsement seed and a fixed template. K never leaves the chip.
2. `tpm2_hmac`: the TPM returns **X** = HMAC-SHA256(K, `"nix-config tpm-host-key v1"`), the same 32 bytes every time.
3. `fido2-assert -G -r -h -v` (optional): after the PIN and a touch, the security key returns **Y**, the hmac-secret of its resident credential. The credential never leaves the key, and Y is always the same.
4. SHA-256(X), or SHA-256(X ‖ Y), seeds an ed25519 key. It is written to `/run/tpm-host-key/ssh_host_ed25519_key` (tmpfs, 0600) in the initrd, before agenix runs.

### Limitations

- Requires the systemd initrd (`boot.initrd.systemd.enable`), the default in NixOS 26.05, and a `keyPath` under `/run/`.
- The key is bound to the TPM, and on firmware TPMs (AMD fTPM, Intel PTT) to the CPU. A new one means a new key, and the host's secrets must be rekeyed. So does a lost security key, or a reset of its FIDO2 application.
- With a security key, every boot needs you for the PIN and a touch. That suits laptops and desktops; unattended servers use the TPM alone.
- With the TPM alone, anyone who can boot code on the board can derive the key, as with any key a machine unlocks without user input.

## Documentation

See the [documentation](./docs/tpm-host-key.md).
