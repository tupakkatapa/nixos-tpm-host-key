{ pkgs
, tpm-host-key
}:
let
  stubbed = pkgs.callPackage ./. { libfido2 = pkgs.callPackage ./fido2-stubs.nix { }; };
in
pkgs.runCommand "tpm-host-key-test" { nativeBuildInputs = [ tpm-host-key pkgs.swtpm pkgs.openssh pkgs.util-linux pkgs.age pkgs.tpm2-tools pkgs.openssl pkgs.unixtools.xxd ]; } ''
  set -euo pipefail
  cd "$(mktemp -d)"
  # Fixed TPM state pins the derivation: a changed label, hash or template
  # would rotate every host's identity
  install -D -m 640 ${./tpm2-00.permall} state/tpm2-00.permall
  swtpm socket --tpm2 --tpmstate dir=state --server type=unixio,path=tpm.sock --ctrl type=unixio,path=tpm.sock.ctrl --flags startup-clear &
  export TPM2TOOLS_TCTI="swtpm:path=$PWD/tpm.sock"
  for _ in $(seq 50); do [ -S tpm.sock ] && break; sleep 0.1; done

  (umask 077; tpm-host-key a; tpm-host-key b)
  [[ $(cat a.pub) == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOpJM+d6zQmlTiJ+IAWi9ym8xaGGUrzH+uJYaVhVy0z7" ]]
  cmp a.pub b.pub
  ssh-keygen -yf a | cmp - a.pub
  [[ $(echo ok | age -e -R a.pub | age -d -i a) == ok ]]

  (umask 022; touch c; tpm-host-key c)
  [[ $(stat -c %a c) == 600 ]]
  cmp a.pub c.pub

  tpm-host-key -- d
  cmp a.pub d.pub

  # The initrd has no /etc/passwd and no nscd
  unshare -rm sh -c 'mount -t tmpfs none /etc && tpm-host-key e'
  cmp a.pub e.pub

  # Without a TPM nothing is written
  if TPM2TOOLS_TCTI=device:/nonexistent tpm-host-key f; then exit 1; fi
  [[ ! -e f && ! -e f.pub ]]
  if tpm-host-key; then exit 1; fi
  if tpm-host-key --bogus g; then exit 1; fi

  fido2() { ${stubbed}/bin/tpm-host-key "$@"; }

  # Enrolling looks for an existing credential first, and only replaces one
  # with --force
  printf '123456\n123456\n' | CREDENTIALS=0 fido2 --fido2-enroll
  [[ -e enrolled ]] && rm enrolled
  if echo 123456 | fido2 --fido2-enroll 2>err; then exit 1; fi
  grep -q -- --force err
  [[ ! -e enrolled ]]
  echo 123456 | fido2 --fido2-enroll --force
  [[ -e enrolled ]]

  # The security key as a second factor: a different key, the same every time
  echo 123456 | fido2 --fido2 g
  echo 123456 | fido2 --fido2 h
  cmp g.pub h.pub
  ! cmp -s a.pub g.pub
  [[ $(cat g.pub) == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7puzyTFSsHzJz9QTzZsslmdK6BCPtTMnEu3jfdsnCl" ]]
  ssh-keygen -yf g | cmp - g.pub

  # Nothing written on failure, and libfido2's errors say what to do
  if echo 000000 | fido2 --fido2 i 2>err; then exit 1; fi
  grep -qx "error: wrong PIN" err
  [[ ! -e i && ! -e i.pub ]]
  if echo 123456 | CREDENTIALS=0 fido2 --fido2 j 2>err; then exit 1; fi
  grep -q -- --fido2-enroll err
  [[ ! -e j && ! -e j.pub ]]
  if echo 123456 | CREDENTIALS=2 fido2 --fido2 k; then exit 1; fi
  [[ ! -e k && ! -e k.pub ]]

  [[ $(fido2 --fido2-retries) == 8 ]]
  [[ $(RETRIES=5 fido2 --fido2-retries) == 5 ]]

  if fido2 --fido2-enroll l; then exit 1; fi
  if fido2 --fido2 --fido2-enroll; then exit 1; fi
  if fido2 --force m; then exit 1; fi

  touch $out
''
