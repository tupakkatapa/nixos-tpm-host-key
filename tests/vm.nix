{ pkgs
, module
}:
let
  keyPath = "/run/tpm-host-key/ssh_host_ed25519_key";

  host = extra: {
    imports = [ module extra ];
    virtualisation.tpm.enable = pkgs.lib.mkDefault true;
    # The serial port as /dev/console, where the test types the PIN
    virtualisation.graphics = false;
    services.openssh.enable = true;
    services.tpmHostKey.enable = true;
    # What agenix would find: whether the key exists when activation runs at boot
    system.activationScripts.keyProbe = {
      deps = [ "specialfs" ];
      text = ''
        if [[ -n ''${IN_NIXOS_SYSTEMD_STAGE1:-} ]]; then
          if [[ -s ${keyPath} ]]; then echo present; else echo absent; fi >/run/key-at-activation
        fi
      '';
    };
  };

  # The stand-in FIDO2 tools in place of libfido2
  stubbed = {
    services.tpmHostKey = {
      package = pkgs.callPackage ../packages/tpm-host-key {
        libfido2 = pkgs.callPackage ../packages/tpm-host-key/fido2-stubs.nix { };
      };
      fido2.enable = true;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "tpm-host-key";

  nodes = {
    tpm = host { };
    notpm = host { virtualisation.tpm.enable = false; };
    fido2 = host stubbed;
    # The real libfido2 in the initrd, with no security key plugged in
    nokey = host { services.tpmHostKey.fido2.enable = true; };
  };

  testScript = ''
    key = "${keyPath}"
    prompt = "enter the PIN, then touch the security key"

    def check_derived(machine):
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep -x present /run/key-at-activation")
        machine.succeed("grep -x derived /run/tpm-host-key.status")
        machine.succeed("systemctl is-active tpm-host-key-status")
        machine.succeed(f"[ $(stat -c %a {key}) = 600 ]")
        machine.succeed(f"ssh-keygen -yf {key} | cmp - {key}.pub")
        machine.wait_for_unit("sshd.service")
        pub = machine.succeed(f"cut -d' ' -f1-2 {key}.pub").strip()
        served = machine.succeed("ssh-keyscan -q -t ed25519 127.0.0.1 2>/dev/null | grep -v '^#' | cut -d' ' -f2-").strip()
        assert served == pub, f"sshd serves {served!r}, not {pub!r}"
        return pub

    def check_failed(machine):
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep -x absent /run/key-at-activation")
        machine.succeed("grep '^failed' /run/tpm-host-key.status")
        machine.fail("systemctl is-active tpm-host-key-status")
        machine.fail(f"test -e {key}")
        machine.fail("systemctl is-active sshd")

    with subtest("TPM alone: derived in the initrd, the same after a reboot"):
        tpm.start()
        first = check_derived(tpm)
        tpm.shutdown()
        tpm.start()
        assert check_derived(tpm) == first

    with subtest("TPM alone: nixos-rebuild switch derives a missing key"):
        tpm.succeed(f"rm {key} {key}.pub && /run/current-system/activate")
        assert tpm.succeed(f"cut -d' ' -f1-2 {key}.pub").strip() == first

    with subtest("No TPM: no key, a failed status, and the boot goes on"):
        notpm.start()
        check_failed(notpm)

    with subtest("Security key: a wrong PIN, then the right one"):
        fido2.start()
        fido2.wait_for_console_text(prompt)
        fido2.send_console("975310\n")
        fido2.wait_for_console_text("error: wrong PIN")
        fido2.wait_for_console_text(prompt)
        fido2.send_console("123456\n")
        combined = check_derived(fido2)
        # Differs from the TPM alone, and the running system derives it again
        tpm_only = fido2.succeed("tpm-host-key /tmp/t && cut -d' ' -f1-2 /tmp/t.pub").strip()
        assert combined != tpm_only
        fido2.succeed(f"echo 123456 | tpm-host-key --fido2 /tmp/f && cut -d' ' -f1-2 /tmp/f.pub | cmp - <(cut -d' ' -f1-2 {key}.pub)")

    with subtest("Security key: three wrong PINs leave no key, and the documented recovery works"):
        fido2.shutdown()
        fido2.start()
        for _ in range(3):
            fido2.wait_for_console_text(prompt)
            fido2.send_console("975310\n")
        check_failed(fido2)
        # The PIN never reaches the status file or the journal
        fido2.fail("grep -F 975310 /run/tpm-host-key.status")
        fido2.fail("journalctl -b | grep -F 975310")
        fido2.succeed(f"echo 123456 | tpm-host-key --fido2 {key}")
        fido2.succeed("/run/current-system/activate")
        fido2.succeed("systemctl reset-failed && systemctl restart sshd")
        fido2.wait_for_unit("sshd.service")
        fido2.succeed(f"ssh-keyscan -q -t ed25519 127.0.0.1 2>/dev/null | grep -F \"$(cut -d' ' -f2 {key}.pub)\"")

    with subtest("Real libfido2 in the initrd, no security key: it waits, then gives up"):
        nokey.start()
        nokey.wait_for_console_text("insert the security key")
        nokey.wait_for_console_text("no FIDO2 security key found")
        check_failed(nokey)
  '';
}
