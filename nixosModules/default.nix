# tpm-host-key: one ed25519 key derived from the TPM at every boot, serving as
# the sshd host key and, with agenix, its identity. Nothing secret is stored.
{ config, options, lib, pkgs, ... }:
let
  cfg = config.services.tpmHostKey;
  key = lib.escapeShellArg cfg.keyPath;
  status = "/run/tpm-host-key.status";
  exe = lib.getExe cfg.package;
  ask = lib.getExe' config.boot.initrd.systemd.package "systemd-ask-password";
  timeout = lib.getExe' pkgs.coreutils "timeout";

  # With a security key, as many as it allows per insertion
  attempts = if cfg.fido2.enable then 3 else 1;
  # PIN tries kept back from the boot prompt, for deriving in the running
  # system, where the keyboard layout is certain; at zero the key needs a reset
  reserve = 3;

  # Before each attempt with a security key: wait for it, and stop while PIN
  # tries are still left for the running system
  check = lib.optionalString cfg.fido2.enable ''
    left=$(${exe} --fido2-retries 2> >(tee -a "$log" >&2)) || break
    if ((left <= ${toString reserve})); then
      echo "error: only $left PIN tries left on the security key; derive the key in the running system" | tee -a "$log" >&2
      break
    fi
  '';
  run =
    if cfg.fido2.enable
    then ''${ask} --timeout=0 --id=tpm-host-key "Security key PIN for the host key (attempt $attempt/${toString attempts}, $left tries left):" | ${exe} --verbose --fido2 ${key}''
    else "${timeout} 60 ${exe} --verbose ${key}";

  # Writes the key and the outcome to the status file; fails without a key
  derive = ''
    install -d -m 700 "$(dirname ${key})"
    # Stays if the unit times out waiting for the PIN
    echo "failed, timed out" >${status}
    log=$(mktemp)
    rc=1
    for ((attempt = 1; attempt <= ${toString attempts}; attempt++)); do
      ${check}
      if (umask 077 && ${run}) 2> >(tee -a "$log" >&2); then
        echo derived >${status}
        rm -f "$log"
        exit 0
      else
        rc=$?
      fi
      # tee may still be writing
      wait $! || true
    done
    printf 'failed, exit %s\n%s\n' "$rc" "$(cat "$log")" >${status}
    rm -f ${key} ${key}.pub "$log"
    exit 1
  '';
in
{
  options.services.tpmHostKey = {
    enable = lib.mkEnableOption "a host key derived from the TPM";
    fido2.enable = lib.mkEnableOption "a FIDO2 security key as a second factor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/tpm-host-key { };
      defaultText = lib.literalMD "this flake's `tpm-host-key`, built with the host's nixpkgs";
      description = "The tpm-host-key package.";
    };
    keyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/tpm-host-key/ssh_host_ed25519_key";
      description = "Where the private key is written, under /run; the public key goes next to it with a .pub suffix.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = "services.tpmHostKey derives the key in the systemd initrd; set boot.initrd.systemd.enable";
      }
      {
        assertion = lib.hasPrefix "/run/" cfg.keyPath;
        message = "services.tpmHostKey.keyPath must be under /run/, the only place the initrd hands over to the system";
      }
    ];

    # For learning the public key, enrolling, and deriving again after a failed boot
    environment.systemPackages = [ cfg.package ];

    # The initrd copies listed paths and their libraries, not the tools the
    # wrapper puts on PATH
    boot.initrd.systemd.storePaths = [ cfg.package ]
      ++ map lib.getBin (cfg.package.tpmInputs ++ lib.optionals cfg.fido2.enable cfg.package.fido2Inputs);

    # Before activation, which runs in the initrd, and so before agenix; /run is
    # carried over to the system
    boot.initrd.systemd.services.tpm-host-key = {
      description = "Derive the SSH host key";
      wantedBy = [ "initrd.target" ];
      before = [ "initrd-nixos-activation.service" ];
      # Pulled in by systemd's TPM generator when the firmware reports a TPM;
      # wanting it here would wait for a device that never comes
      after = [ "tpm2.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A wedged TPM must not hold the boot; with a security key, time to
        # plug it in, type the PIN and touch it
        TimeoutStartSec = if cfg.fido2.enable then "5min" else "1min";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = derive;
    };

    # nixos-rebuild switch on a running system that has no key yet; at boot the
    # initrd unit has already had its try. A security key needs the boot prompt.
    system.activationScripts.tpmHostKey = {
      deps = [ "specialfs" ];
      text = ''
        if [[ ! -e ${key} && -z ''${IN_NIXOS_SYSTEMD_STAGE1:-} ]]; then
          ${if cfg.fido2.enable
            then ''echo "tpm-host-key: no host key until the next boot asks for the security key's PIN" >&2''
            else ''(${derive}) || true''}
        fi
      '';
    };

    # The initrd journal does not always survive switch-root; /run does, so the
    # outcome is replayed into the journal, and the unit fails without a key
    systemd.services.tpm-host-key-status = {
      description = "Report the SSH host key derivation";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        cat ${status}
        grep -qx derived ${status}
      '';
    };

    # Not in hostKeys: sshd's pre-start would generate a random key in place of
    # a failed derivation
    services.openssh = {
      hostKeys = [ ];
      extraConfig = "HostKey ${cfg.keyPath}";
    };
  }
    (lib.optionalAttrs (options ? age) {
      system.activationScripts.agenixInstall.deps = [ "tpmHostKey" ];
      age.identityPaths = [ cfg.keyPath ];
    })]);
}
