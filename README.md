# ldk-server-nixos

Nix packages and a NixOS service module for
[LDK Server](https://github.com/lightningdevkit/ldk-server).
This is an independently maintained project, extracted from
[LDK Server PR #260](https://github.com/lightningdevkit/ldk-server/pull/260).

The upstream source and Nixpkgs are pinned in `flake.lock`. This repository
contains the packaging and service module; Nix fetches the Rust source from
upstream. The package version comes from upstream's Cargo manifest, and the
binary records the upstream commit.

Packages are available for `x86_64-linux`, `aarch64-linux`, and
`aarch64-darwin`. The service module requires NixOS. Enable the `nix-command`
and `flakes` experimental features in Nix before you use these commands.

The flake builds `ldk-server` and `ldk-server-cli`. It also provides a NixOS
module for the daemon.

## Run without installing

Clone this repository, then build both binaries:

```bash
git clone https://github.com/benthecarman/ldk-server-nixos.git
cd ldk-server-nixos
nix build
```

The binaries are in `result/bin`. To run the server, supply a configuration
file as described in the upstream
[getting started guide](https://github.com/lightningdevkit/ldk-server/blob/main/docs/getting-started.md):

```bash
nix run . -- /path/to/config.toml
```

Run the command-line client:

```bash
nix run .#ldk-server-cli -- --help
```

## Deploy on NixOS

Add the flake to your system inputs:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ldk-server-nixos.url = "github:benthecarman/ldk-server-nixos";

  outputs = { nixpkgs, ldk-server-nixos, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ldk-server-nixos.nixosModules.default
        {
          services.ldk-server.instances = {
            mainnet = {
              enable = true;
              openFirewall = true;
              lightningPort = 9735;
              settings = {
                node = {
                  network = "bitcoin";
                  listening_addresses = [ "0.0.0.0:9735" ];
                  grpc_service_address = "127.0.0.1:3536";
                };
                esplora.server_url = "https://mempool.space/api";
                log = {
                  level = "Info";
                  log_to_file = false;
                };
              };
            };

            signet = {
              enable = true;
              lightningPort = 19735;
              grpcPort = 13536;
              settings = {
                node = {
                  network = "signet";
                  listening_addresses = [ "127.0.0.1:19735" ];
                  grpc_service_address = "127.0.0.1:13536";
                };
                esplora.server_url = "https://mempool.space/signet/api";
              };
            };
          };
        }
      ];
    };
  };
}
```

By default, each instance gets a separate service, user, configuration, and
data directory. For example, `mainnet` uses `ldk-server-mainnet.service` and
stores data in `/var/lib/ldk-server/mainnet`.

Use different Lightning and gRPC addresses for each instance. The module sets
each data path even if the TOML file contains a different storage path.

The example exposes the Lightning port but keeps the gRPC API on loopback.
Before you expose gRPC, configure its certificate and client access as
described in [Operations - TLS](https://github.com/lightningdevkit/ldk-server/blob/main/docs/operations.md#tls).

The `settings` option writes values to the Nix store. Do not put passwords or
other secrets in this option. Use `environmentFiles` for secrets:

```nix
services.ldk-server.instances.mainnet.environmentFiles = [
  "/run/secrets/ldk-server-mainnet"
];
```

The file can override supported settings with environment variables:

```text
LDK_SERVER_BITCOIND_RPC_USER=rpc-user
LDK_SERVER_BITCOIND_RPC_PASSWORD=rpc-password
```

You can also set an instance's `configFile` to a complete TOML file. You
cannot use `configFile` and `settings` on the same instance.

After deployment, inspect the service with this command:

```bash
systemctl status ldk-server-mainnet
```

To use a complete configuration file, supply its runtime path as a string:

```nix
services.ldk-server.instances.mainnet = {
  enable = true;
  configFile = "/run/secrets/ldk-server-mainnet.toml";
};
```

The service user must be able to read this file. Systemd reads
`environmentFiles`, so those files can remain owned by root. Custom `user`
and `group` values must refer to users and groups in your NixOS configuration.

## Update upstream

You can select an upstream commit or release tag in your system flake without
waiting for this repository or Nixpkgs to update. Add a source input and make
the module's source input follow it:

```nix
inputs.ldk-server-nixos.url = "github:benthecarman/ldk-server-nixos";
inputs.ldk-server-src = {
  url = "github:lightningdevkit/ldk-server/<commit-or-tag>";
  flake = false;
};
inputs.ldk-server-nixos.inputs.ldk-server-src.follows = "ldk-server-src";
```

Replace `<commit-or-tag>` with a full commit hash or an existing release tag.
The module uses that source automatically; no package override is needed.
The binaries' version strings include the selected upstream commit.

To follow upstream `main`, use `github:lightningdevkit/ldk-server/main` as
the source URL. Then run these commands from your system flake directory:

```bash
nix flake update ldk-server-src
sudo nixos-rebuild switch --flake .#my-host
```

Nix keeps the selected commit in your `flake.lock`; it only moves when you
update it. To change a fixed commit or tag, edit the source URL first.
Keep the updated lock file in version control.

The build reads dependencies from the selected source's `Cargo.lock`, including
Git revisions and registry checksums. There are no extra dependency hashes to
maintain here. Nix can fetch Git dependencies during evaluation, so the first
evaluation of a new revision needs network access. The initial repository
downloads can be large; Nix caches them for later use. This uses Nixpkgs'
[`allowBuiltinFetchGit` support](https://github.com/NixOS/nixpkgs/blob/master/doc/languages-frameworks/rust.section.md).

A future upstream change to the build layout, required Rust version, or service
configuration can still need packaging or configuration changes. If a new
compiler is required, you can also override this flake's `nixpkgs` input in
your system flake.

To update this repository's default source pin, run these commands from its
checkout:

```bash
nix flake update ldk-server-src
nix flake check --print-build-logs
```

To update Nixpkgs separately, run `nix flake update nixpkgs`.
The module uses this flake's package by default. Set
`services.ldk-server.package` to use a different build.

## Development

```bash
nix fmt
nix flake check --all-systems --no-build
nix flake check --print-build-logs
```

The build check compiles the server and CLI, runs their Rust unit tests, and
installs Bash, Fish, and Zsh completions. The Linux VM test uses a test daemon
to check systemd startup, separate users and data directories, generated and
external configuration, environment files, firewall rules, and independent
service shutdown. It does not test Lightning payments or chain synchronization.
Linux VM tests need KVM. CI runs the build and VM checks on x86_64 Linux.

## License

MIT or Apache-2.0, at your option. See [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE).
