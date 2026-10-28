#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

# Part of every host's identity: changing it rotates every derived key
readonly label="nix-config tpm-host-key v1"
# The relying party of the security key's resident credential
readonly rp="tpm-host-key"
verbose=false
mode=derive
fido2=false
force=false

display_usage() {
  cat <<USAGE
Usage: tpm-host-key [-v] [--fido2] OUT
       tpm-host-key [-v] --fido2-enroll [--force]
       tpm-host-key --fido2-retries

Description:
  Write an OpenSSH ed25519 host key to OUT and its public half to OUT.pub,
  derived from this machine's TPM: an HMAC by a deterministic primary in the
  endorsement hierarchy. Nothing is stored; the same TPM yields the same key
  on every run, also after tpm2_clear.

  With --fido2, the key also depends on a FIDO2 security key: the hmac-secret
  of its resident credential, which needs the PIN and a touch. The PIN is read
  from the terminal, or from stdin without one.

Options:
  --fido2          Mix in the security key's hmac-secret
  --fido2-enroll   Create the resident credential, once per security key
  --force          Replace an existing credential; rotates every key derived
                   with it
  --fido2-retries  Wait for the security key, print its remaining PIN tries
  -v, --verbose    Enable verbose output
  -h, --help       Show this help

Environment:
  TPM2TOOLS_TCTI   TPM connection (default: device:/dev/tpmrm0)
USAGE
}

# Output function with optional verbose-only mode and timestamps
# Usage:
#   say "message"          - always shown (with timestamp if verbose enabled)
#   say verbose "message"  - only shown when verbose flag is set
say() {
  local message
  local verbose_only=false

  if [[ $1 == "verbose" ]]; then
    verbose_only=true
    shift
  fi

  message="$*"

  if [[ $verbose_only == true ]] && [[ $verbose == false ]]; then
    return
  fi

  if [[ $verbose == true ]]; then
    echo "[$(date '+%H:%M:%S')] $message" >&2
  else
    echo "$message" >&2
  fi
}

die() {
  say "$@"
  exit 1
}

# Bytes travel as lowercase hex in shell variables and reach other programs
# only through pipes, so the key never touches the disk or an argument list
hex() { xxd -p | tr -d '\n'; }
unhex() { printf '%s' "$1" | xxd -r -p; }
sha256() { unhex "$1" | sha256sum | cut -d' ' -f1; }

# SSH wire string: a 4-byte big-endian length, then the bytes
sshstr() { printf '%08x%s' $((${#1} / 2)) "$1"; }

# 32 bytes only this TPM can produce: an HMAC of the label by a primary key
# that the TPM recreates from its endorsement seed and this exact template
tpm_secret() {
  local ctx="$1" mac

  unhex "$digest" |
    tpm2_createprimary -Q -C e -G hmac -g sha256 \
      -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign' \
      -u - -c "$ctx"
  # Raw TPM devices and swtpm keep the transient primary loaded until flushed
  tpm2_flushcontext -t

  mac=$(printf '%s' "$label" | tpm2_hmac -c "$ctx" | hex)
  tpm2_flushcontext -t
  [[ $mac =~ ^[0-9a-f]{64}$ ]] || die "error: unexpected HMAC from the TPM"
  printf '%s' "$mac"
}

# The public key of an ed25519 seed: PKCS#8 for ed25519 is a fixed DER prefix
# and the seed, and the key is the last 32 bytes of its SubjectPublicKeyInfo
ed25519_public() {
  unhex "302e020100300506032b657004220420$1" |
    openssl pkey -inform DER -pubout -outform DER |
    tail -c 32 | hex
}

# The key as SSH encodes it: type name, then the 32 public bytes
ssh_public_blob() {
  sshstr "$(printf '%s' ssh-ed25519 | hex)"
  sshstr "$1"
}

# OpenSSH's private key format (PROTOCOL.key), unencrypted. ssh-keygen would
# write it, but aborts when getpwuid() fails, and the initrd has no
# /etc/passwd.
openssh_private_key() {
  local seed="$1" pub="$2" blob="$3" none header private pad=1

  none=$(printf '%s' none | hex)
  # Magic, no cipher, no KDF, empty KDF options, one key
  header="$(printf 'openssh-key-v1\0' | hex)$(sshstr "$none")$(sshstr "$none")$(sshstr "")00000001"
  # Two equal check ints, the key, an empty comment, padded to the 8-byte block
  private="0000000000000000$blob$(sshstr "$seed$pub")$(sshstr "")"
  while (((${#private} / 2) % 8)); do
    private+=$(printf '%02x' "$pad")
    pad=$((pad + 1))
  done

  echo "-----BEGIN OPENSSH PRIVATE KEY-----"
  unhex "$header$(sshstr "$blob")$(sshstr "$private")" | base64 -w 70
  echo "-----END OPENSSH PRIVATE KEY-----"
}

# The first security key; waits for one to be plugged in
fido2_device() {
  local dev second

  for second in {1..60}; do
    dev=$(fido2-token -L)
    if [[ -n $dev ]]; then
      printf '%s' "${dev%%:*}"
      return
    fi
    ((second > 1)) || say "insert the security key"
    sleep 1
  done
  die "error: no FIDO2 security key found"
}

# Runs a libfido2 tool, turning its known errors into what to do about them
fido2_run() {
  local err="$tmp/fido2.err" rc=0

  "$@" 2>"$err" || rc=$?
  ((rc == 0)) && return
  case $(<"$err") in
  *FIDO_ERR_NO_CREDENTIALS*) die "error: no $rp credential on the security key; enrol one with --fido2-enroll" ;;
  *FIDO_ERR_PIN_INVALID*) die "error: wrong PIN" ;;
  *FIDO_ERR_PIN_AUTH_BLOCKED*) die "error: too many wrong PINs; remove and reinsert the security key" ;;
  *FIDO_ERR_PIN_BLOCKED*) die "error: the PIN is blocked; only a reset of the security key recovers, and gives a new key" ;;
  *) die "error: $1 failed: $(<"$err")" ;;
  esac
}

fido2_retries() {
  local dev="$1" info

  info=$(fido2_run fido2-token -I "$dev")
  [[ $info =~ pin\ retries:\ ([0-9]+) ]] || die "error: the security key reports no PIN retries"
  printf '%s' "${BASH_REMATCH[1]}"
}

# Whether the security key holds a credential for the relying party; asks for
# the PIN
fido2_enrolled() {
  local dev="$1" err="$tmp/list.err" list rc=0

  say "enter the PIN to look for an existing credential"
  list=$(fido2-token -L -k "$rp" "$dev" 2>"$err") || rc=$?
  ((rc == 0)) && [[ -n $list ]] && return
  ((rc == 0)) || grep -q FIDO_ERR_NO_CREDENTIALS "$err" || die "error: fido2-token failed: $(<"$err")"
  return 1
}

# A resident credential with hmac-secret that the security key only uses with
# user verification (credProtect 3), so the PIN is required on any key
fido2_enroll() {
  local request="$1" dev

  dev=$(fido2_device)
  if [[ $force == false ]] && fido2_enrolled "$dev"; then
    die "error: the security key already has a $rp credential; replacing it rotates every key derived with it (--force)"
  fi
  # Client data hash, relying party, user name, user id
  printf '%s\n%s\n%s\n%s\n' "$challenge" "$rp" "$rp" "$challenge" >"$request"
  say "enter the PIN, then touch the security key"
  fido2_run fido2-cred -M -r -h -c 3 -t pin=true -i "$request" "$dev" >/dev/null
}

# 32 bytes only this security key can produce: the hmac-secret of its resident
# credential, with user verification so the PIN is required every time
fido2_secret() {
  local request="$1" dev assertion lines mac

  dev=$(fido2_device)
  # Client data hash, relying party, hmac salt
  printf '%s\n%s\n%s\n' "$challenge" "$rp" "$challenge" >"$request"
  say "enter the PIN, then touch the security key"
  assertion=$(fido2_run fido2-assert -G -r -h -v -i "$request" "$dev")
  mapfile -t lines <<<"$assertion"
  # One assertion is six lines; more means several credentials for the party
  [[ ${#lines[@]} -eq 6 ]] || die "error: expected exactly one $rp credential on the security key"
  mac=$(base64 -d <<<"${lines[5]}" | hex)
  [[ $mac =~ ^[0-9a-f]{64}$ ]] || die "error: unexpected hmac-secret from the security key"
  printf '%s' "$mac"
}

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --fido2)
    fido2=true
    shift
    ;;
  --fido2-enroll)
    mode=enroll
    shift
    ;;
  --force)
    force=true
    shift
    ;;
  --fido2-retries)
    mode=retries
    shift
    ;;
  -v | --verbose)
    verbose=true
    shift
    ;;
  -h | --help)
    display_usage
    exit 0
    ;;
  --)
    shift
    positional+=("$@")
    break
    ;;
  -*) die "error: unknown flag: $1" ;;
  *)
    positional+=("$1")
    shift
    ;;
  esac
done
case $mode in
derive)
  [[ ${#positional[@]} -eq 1 && $force == false ]] || {
    display_usage >&2
    exit 1
  }
  out="${positional[0]}"
  tools=(tpm2_createprimary tpm2_hmac tpm2_flushcontext openssl)
  [[ $fido2 == false ]] || tools+=(fido2-token fido2-assert)
  ;;
enroll)
  [[ ${#positional[@]} -eq 0 && $fido2 == false ]] || die "error: --fido2-enroll takes no OUT or --fido2"
  tools=(fido2-token fido2-cred)
  ;;
retries)
  [[ ${#positional[@]} -eq 0 && $fido2 == false && $force == false ]] || die "error: --fido2-retries takes no other arguments"
  tools=(fido2-token)
  ;;
esac
for tool in "${tools[@]}" xxd base64 sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "error: $tool not found in PATH"
done

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
digest=$(sha256 "$(printf '%s' "$label" | hex)")
# Client data hash, hmac salt and user id; none is secret, all must stay fixed
challenge=$(unhex "$digest" | base64 -w 0)

case $mode in
enroll)
  fido2_enroll "$tmp/cred"
  say "enrolled the $rp credential"
  exit 0
  ;;
retries)
  device=$(fido2_device)
  fido2_retries "$device"
  echo
  exit 0
  ;;
esac

export TPM2TOOLS_TCTI="${TPM2TOOLS_TCTI:-device:/dev/tpmrm0}"
say verbose "deriving from the TPM ($TPM2TOOLS_TCTI)"
secret=$(tpm_secret "$tmp/primary.ctx")
if [[ $fido2 == true ]]; then
  say verbose "deriving from the security key"
  secret+=$(fido2_secret "$tmp/assert")
fi
seed=$(sha256 "$secret")
pub=$(ed25519_public "$seed")
[[ $pub =~ ^[0-9a-f]{64}$ ]] || die "error: could not compute the public key"
blob=$(ssh_public_blob "$pub")

# Both files are built in full before either is written
private_key=$(openssh_private_key "$seed" "$pub" "$blob")
public_key="ssh-ed25519 $(unhex "$blob" | base64 -w 0)"

install -m 600 /dev/null "$out"
printf '%s\n' "$private_key" >"$out"
printf '%s\n' "$public_key" >"$out.pub"
say verbose "wrote $out and $out.pub"
