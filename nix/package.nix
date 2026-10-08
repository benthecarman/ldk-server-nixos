{
  installShellFiles,
  lib,
  openssl,
  pkg-config,
  rustPlatform,
  stdenv,
  src,
  gitHash ? "unknown",
  cargoHash ? "sha256-rkPiojKba+0DlYa5RFKg2eUz7/p9fctu3Eu9JKukGWY=",
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "ldk-server";
  version = (builtins.fromTOML (builtins.readFile "${src}/ldk-server/Cargo.toml")).package.version;

  inherit src;

  # Fetch the locked dependencies as a hash-checked vendor tree before the
  # offline build. Upstream overrides can supply a new cargoHash as needed.
  inherit cargoHash;
  cargoDepsName = "ldk-server";

  GIT_HASH = gitHash;

  nativeBuildInputs = [
    installShellFiles
    pkg-config
  ];

  # ldk-node's PostgreSQL storage backend links native-tls.
  buildInputs = [ openssl ];

  cargoBuildFlags = [
    "-p"
    "ldk-server"
    "-p"
    "ldk-server-cli"
  ];
  cargoTestFlags = finalAttrs.cargoBuildFlags;
  checkType = "debug";

  installPhase = ''
    runHook preInstall

    releaseDir="target/${stdenv.hostPlatform.rust.rustcTarget}/release"
    install -Dm755 "$releaseDir/ldk-server" "$out/bin/ldk-server"
    install -Dm755 "$releaseDir/ldk-server-cli" "$out/bin/ldk-server-cli"

    ${lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      completionDir="$(mktemp -d)"
      "$releaseDir/ldk-server-cli" completions bash > "$completionDir/ldk-server-cli.bash"
      "$releaseDir/ldk-server-cli" completions fish > "$completionDir/ldk-server-cli.fish"
      "$releaseDir/ldk-server-cli" completions zsh > "$completionDir/_ldk-server-cli"

      installShellCompletion --cmd ldk-server-cli \
        --bash "$completionDir/ldk-server-cli.bash" \
        --fish "$completionDir/ldk-server-cli.fish" \
        --zsh "$completionDir/_ldk-server-cli"
    ''}

    runHook postInstall
  '';

  meta = {
    description = "Ready-to-run Lightning node daemon built with LDK Node";
    homepage = "https://github.com/lightningdevkit/ldk-server";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "ldk-server";
  };
})
