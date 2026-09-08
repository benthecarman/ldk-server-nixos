{
  installShellFiles,
  lib,
  rustPlatform,
  stdenv,
  src,
  gitHash ? "unknown",
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "ldk-server";
  version = (builtins.fromTOML (builtins.readFile "${src}/ldk-server/Cargo.toml")).package.version;

  inherit src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    # Use the Git revisions in the selected source's lock file so users can
    # update upstream without maintaining a second set of dependency hashes.
    allowBuiltinFetchGit = true;
  };

  GIT_HASH = gitHash;

  nativeBuildInputs = [ installShellFiles ];

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
