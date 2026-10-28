# NixOS TPM Host Key

## Getting Started

1. Add the module to your flake:

   ```nix
   {
     inputs = {
       nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
       tpm-host-key.url = "github:tupakkatapa/nixos-tpm-host-key";
     };

     outputs = { nixpkgs, tpm-host-key, ... }: {
       nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
         modules = [
           tpm-host-key.nixosModules.default
           { services.tpmHostKey.enable = true; }
         ];
       };
     };
   }
   ```

2. Learn the host's public key, on the host:

   ```bash
   sudo nix run github:tupakkatapa/nixos-tpm-host-key -- /tmp/k && cat /tmp/k.pub && sudo rm /tmp/k /tmp/k.pub
   ```

3. Put it in `programs.ssh.knownHosts` and, with [agenix-rekey](https://github.com/oddlama/agenix-rekey), in `age.rekey.hostPubkey`. Then run `agenix rekey -a` and rebuild.

## Configuration Options

| Option | Default | Description |
|---|---|---|
| `services.tpmHostKey.enable` | `false` | Derive the host key from the TPM |
| `services.tpmHostKey.fido2.enable` | `false` | Also require a FIDO2 security key, with its PIN and a touch at boot |
| `services.tpmHostKey.package` | this flake's, built with the host's nixpkgs | The `tpm-host-key` package |
| `services.tpmHostKey.keyPath` | `/run/tpm-host-key/ssh_host_ed25519_key` | Private key path, under `/run/`; the public key gets a `.pub` suffix |

## Security Key as a Second Factor

With `fido2.enable`, the key also needs a FIDO2 security key: at boot, the initrd waits for it, asks for its PIN, then for a touch. Someone has to be there.

1. Enrol the credential, once per security key. It needs a FIDO2 PIN (e.g. `ykman fido access change-pin`) and credProtect support, which YubiKeys have from firmware 5.2:

   ```bash
   sudo tpm-host-key --fido2-enroll
   ```

   One credential serves any number of hosts, each with its own key from its TPM. If the security key already has one, enrolling stops; `--force` replaces it, which rotates every key derived with it.

2. Learn the host's public key; this asks for the PIN and a touch:

   ```bash
   sudo tpm-host-key --fido2 /tmp/k && cat /tmp/k.pub && sudo rm /tmp/k /tmp/k.pub
   ```

3. Set `services.tpmHostKey.fido2.enable = true`, update `hostPubkey` and `knownHosts`, run `agenix rekey -a`, then `nixos-rebuild boot` and reboot: the running system keeps its key until then. If the PIN has characters that differ between keyboard layouts, also set `console.earlySetup = true`, so the initrd uses yours.

Wrong PINs count toward the security key's own limit (8 on a YubiKey), and once it is reached, only a reset recovers it, which deletes the credential. The boot prompt shows the tries left and stops at three, keeping them for the running system.

A lost or reset security key means a new key: rekey from your master identities.

## Troubleshooting

```bash
cat /run/tpm-host-key.status                      # derived
sudo ssh-keygen -lf /run/tpm-host-key/ssh_host_ed25519_key.pub
```

Without a key, the status reads `failed, exit N` or `failed, timed out`, followed by the output of the initrd's `tpm-host-key.service`, and `tpm-host-key-status.service` fails. Nothing is written in its place: sshd exits with `no hostkeys available` and secrets stay sealed. Check that the TPM is enabled in firmware and that `/dev/tpmrm0` exists.

Rebooting tries again. To derive the key in the running system instead (drop `--fido2` without a security key; this needs a login that does not depend on the host's secrets):

```bash
sudo tpm-host-key --fido2 /run/tpm-host-key/ssh_host_ed25519_key
sudo /run/current-system/activate    # with systemd-sysusers or userborn: systemctl restart agenix-install-secrets
sudo systemctl reset-failed
sudo systemctl restart sshd          # and the other services that use the secrets
```

## Without Nix

The script needs only `tpm2-tools`, `openssl`, `xxd` and coreutils, plus `libfido2` for a security key:

```bash
curl -O https://raw.githubusercontent.com/tupakkatapa/nixos-tpm-host-key/main/packages/tpm-host-key/tpm-host-key.sh
chmod +x tpm-host-key.sh
sudo ./tpm-host-key.sh --help
```
