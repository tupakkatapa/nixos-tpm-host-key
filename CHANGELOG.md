# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-28

### Added
- `fido2.enable`: a FIDO2 security key as a second factor, with PIN and touch at boot
- `--fido2`, `--fido2-enroll` and `--fido2-retries`, using a resident credential on the security key
- The boot prompt shows the PIN tries left, and stops with three in reserve
- `tpm-host-key` in the system packages

### Changed
- **Breaking:** requires the systemd initrd (`boot.initrd.systemd.enable`, the default in NixOS 26.05)
- **Breaking:** `keyPath` must be under `/run/`
- **Breaking:** the script moved to `packages/tpm-host-key/tpm-host-key.sh`; update raw URLs
- The key is derived in the initrd; derived keys are unchanged
- `tpm-host-key-status` fails when there is no key

## [0.1.0] - 2026-10-27

### Added
- `tpm-host-key`: an ed25519 host key derived from the TPM's endorsement hierarchy
- `services.tpmHostKey`: the key as the sshd host key and agenix identity
