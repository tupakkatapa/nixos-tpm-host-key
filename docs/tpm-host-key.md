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

2. Learn the host's public key by running this on the host:

```bash
sudo nix run github:tupakkatapa/nixos-tpm-host-key -- /tmp/k && cat /tmp/k.pub && sudo rm /tmp/k /tmp/k.pub
```

3. Put the key in `programs.ssh.knownHosts` and, with [agenix-rekey](https://github.com/oddlama/agenix-rekey), in `age.rekey.hostPubkey`. Then run `agenix rekey -a` and rebuild.

## Configuration Options

| Option | Default | Description |
|---|---|---|
| `services.tpmHostKey.enable` | `false` | Derive the host key from the TPM |
| `services.tpmHostKey.package` | this flake's package | The `tpm-host-key` package |
| `services.tpmHostKey.keyPath` | `/run/tpm-host-key/ssh_host_ed25519_key` | Private key path; the public key gets a `.pub` suffix |

## Troubleshooting

```bash
cat /run/tpm-host-key.status                      # derived
sudo ssh-keygen -lf /run/tpm-host-key/ssh_host_ed25519_key.pub
```

On failure, the status reads `failed, exit N`, followed by the script's output. `tpm-host-key-status.service` repeats it in the journal, because the initrd journal does not always survive switch-root. No key is written in its place: sshd exits with `no hostkeys available` and secrets stay sealed. Check that the TPM is enabled in firmware and that `/dev/tpmrm0` exists.

## Without Nix

The script needs only `tpm2-tools`, `openssl`, `xxd` and coreutils:

```bash
curl -O https://raw.githubusercontent.com/tupakkatapa/nixos-tpm-host-key/main/tpm-host-key.sh
chmod +x tpm-host-key.sh
sudo ./tpm-host-key.sh --help
```
