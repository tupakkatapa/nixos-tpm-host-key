{ lib
, stdenv
, callPackage
, makeWrapper
, coreutils
, libfido2
, openssl
, tpm2-tools
, unixtools
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "tpm-host-key";
  version = "0.2.0";
  src = ./tpm-host-key.sh;
  dontUnpack = true;

  buildInputs = finalAttrs.passthru.tpmInputs ++ finalAttrs.passthru.fido2Inputs;

  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -D -m 755 $src $out/bin/${finalAttrs.pname}
    wrapProgram $out/bin/${finalAttrs.pname} \
      --prefix PATH : ${lib.makeBinPath finalAttrs.buildInputs}
  '';

  passthru = {
    # The tools on the wrapper's PATH, split so the initrd only gets libfido2
    # with a security key
    tpmInputs = [ coreutils openssl tpm2-tools unixtools.xxd ];
    fido2Inputs = [ libfido2 ];
    tests.derive = callPackage ./test.nix { tpm-host-key = finalAttrs.finalPackage; };
  };
  meta = {
    description = "OpenSSH ed25519 host key derived from the TPM";
    license = lib.licenses.gpl3Only;
    mainProgram = finalAttrs.pname;
  };
})
