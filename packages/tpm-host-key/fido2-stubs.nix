{ symlinkJoin
, writeShellScriptBin
}:
let
  # Stand-ins for libfido2's tools, held to their man pages and error output:
  # an assertion is six lines and the hmac-secret is the last; the PIN comes on
  # stdin when there is no terminal. The test sets DEVICES=0 to unplug the key,
  # CREDENTIALS to how many it holds, and RETRIES to its PIN retries.
  pin = call: ''
    read -r pin
    if [ "$pin" != 123456 ]; then
      echo "$(basename "$0"): ${call}: FIDO_ERR_PIN_INVALID" >&2
      exit 1
    fi
  '';

  fido2Token = writeShellScriptBin "fido2-token" ''
    set -eu
    case "$*" in
    -L)
      [ "''${DEVICES:-1}" = 0 ] ||
        echo "/dev/hidraw7: vendor=0x1050, product=0x0407 (Yubico YubiKey OTP+FIDO+CCID)"
      ;;
    "-I /dev/hidraw7")
      echo "proto: 0x02"
      echo "pin retries: ''${RETRIES:-8}"
      ;;
    "-L -k tpm-host-key /dev/hidraw7")
      ${pin "fido_credman_get_dev_rk"}
      if [ "''${CREDENTIALS:-1}" = 0 ]; then
        echo "fido2-token: fido_credman_get_dev_rk: FIDO_ERR_NO_CREDENTIALS" >&2
        exit 1
      fi
      echo "00: Y3JlZA== tpm-host-key dXNlcg== es256 uvrequired nopay"
      ;;
    *) exit 1 ;;
    esac
  '';

  fido2Assert = writeShellScriptBin "fido2-assert" ''
    set -eu
    [ "$*" = "-G -r -h -v -i $6 /dev/hidraw7" ]
    ${pin "fido_dev_get_assert"}
    { read -r cdh; read -r rp; read -r salt; } <"$6"
    [ "$rp" = tpm-host-key ] && [ "$salt" = "$cdh" ]
    if [ "''${CREDENTIALS:-1}" = 0 ]; then
      echo "fido2-assert: fido_dev_get_assert: FIDO_ERR_NO_CREDENTIALS" >&2
      exit 1
    fi
    for _ in $(seq "''${CREDENTIALS:-1}"); do
      printf '%s\n' "$cdh" "$rp" authdata signature userid "$(printf '%32s' | tr ' ' '\021' | base64)"
    done
  '';

  fido2Cred = writeShellScriptBin "fido2-cred" ''
    set -eu
    [ "$*" = "-M -r -h -c 3 -t pin=true -i $9 /dev/hidraw7" ]
    ${pin "fido_dev_make_cred"}
    { read -r cdh; read -r rp; read -r user; read -r id; } <"$9"
    [ "$rp" = tpm-host-key ] && [ "$user" = tpm-host-key ] && [ "$id" = "$cdh" ]
    touch enrolled
  '';
in
symlinkJoin {
  name = "fido2-stubs";
  paths = [ fido2Token fido2Assert fido2Cred ];
}
