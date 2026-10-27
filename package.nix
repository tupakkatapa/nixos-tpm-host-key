{ pkgs
, lib
}:
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "tpm-host-key";
  version = "0.1";
  src = ./tpm-host-key.sh;
  dontUnpack = true;

  buildInputs = with pkgs; [
    coreutils
    tpm2-tools
    unixtools.xxd
    openssl
  ];

  nativeBuildInputs = [ pkgs.makeWrapper ];
  installPhase = ''
    install -D -m 755 $src $out/bin/${finalAttrs.pname}
    wrapProgram $out/bin/${finalAttrs.pname} \
      --prefix PATH : ${lib.makeBinPath finalAttrs.buildInputs}
  '';

  passthru.tests.derive = pkgs.callPackage ./tests/derive.nix { tpm-host-key = finalAttrs.finalPackage; };
  meta = {
    description = "OpenSSH ed25519 host key derived from the TPM";
    license = lib.licenses.gpl3Only;
    mainProgram = finalAttrs.pname;
  };
})
