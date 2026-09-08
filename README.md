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
              settings = {
                node = {
                  network = "bitcoin";
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
              lightningPort = 39735;
              grpcPort = 13536;
              settings = {
                node = {
                  network = "signet";
                  listening_addresses = [ "127.0.0.1:39735" ];
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

`lightningPort` defaults to `9735`. Generated configuration listens on
`0.0.0.0` at that port; for example, `lightningPort = 8735;` changes the
listener and the optional firewall rule together. Set
`settings.node.listening_addresses` to choose specific bind addresses.
Explicit listener settings or a complete `configFile` take precedence and
must match `lightningPort` if you enable `openFirewall`. Set `lightningPort`
to `null` to omit the generated listener default and Lightning firewall rule.

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

See [NixOS integration](docs/integration.md) for interface-scoped firewall
rules, local service dependencies, timeout overrides, and runtime secrets
with SOPS or another provider. The module does not depend on a particular
VPN, Bitcoin Core service name, or secret manager.

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
The module uses that source automatically. The binaries' version strings
include the selected upstream commit.

Also override the package's `cargoHash` for your selected source. In your
`nixosSystem.modules` list, with `ldk-server-nixos` in scope from the flake's
`outputs` arguments:

```nix
modules = [
  ldk-server-nixos.nixosModules.default
  ({ lib, pkgs, ... }: {
    services.ldk-server.package =
      ldk-server-nixos.packages.${pkgs.stdenv.hostPlatform.system}.ldk-server.override {
        cargoHash = lib.fakeHash; # Replace with the hash reported by Nix.
      };
  })
  ./configuration.nix
];
```

To follow upstream `main`, use `github:lightningdevkit/ldk-server/main` as
the source URL. Then run these commands from your system flake directory:

```bash
nix flake update ldk-server-src
nix build --no-link .#nixosConfigurations.my-host.config.services.ldk-server.package.cargoDeps
```

The first build with `lib.fakeHash` is expected to fail with a hash mismatch.
Replace `lib.fakeHash` with the quoted `sha256-...` value on the `got:` line,
then build and apply your system:

```bash
nix build --no-link .#nixosConfigurations.my-host.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#my-host
```

Nix keeps the selected commit in your `flake.lock`; it only moves when you
update it. To change a fixed commit or tag, edit the source URL first. Use
`lib.fakeHash` again to check the dependency hash when you change the source;
otherwise Nix can reuse a cached vendor tree with the old hash. Keep the
source pin, lock file, and dependency hash in version control.

The package uses Nixpkgs' `fetchCargoVendor` with one `cargoHash` for the
locked dependencies. Downloads run in a separate build step, before offline
compilation. Dependency fetching does not run during Nix evaluation. Git
dependencies still need downloads, but the fetcher first tries a shallow
fetch of each pinned revision. Nix caches the resulting vendor tree.

A future upstream change to the build layout, required Rust version, or service
configuration can still need packaging or configuration changes. If a new
compiler is required, you can also override this flake's `nixpkgs` input in
your system flake.

To update this repository's default source pin, run these commands from its
checkout:

```bash
nix flake update ldk-server-src
```

Set the default `cargoHash` in `nix/package.nix` to `lib.fakeHash`, run
`nix build --no-link .#ldk-server.cargoDeps`, and replace it with the reported
hash. Then run `nix flake check --print-build-logs`.

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
installs Bash, Fish, and Zsh completions. The module VM test uses a test daemon
to check systemd startup, separate users and data directories, generated and
external configuration, environment files, firewall rules, timeout overrides,
and independent service shutdown. A second VM test starts the real server
with a local regtest Bitcoin Core backend, checks API access and node identity
across a restart, and checks allowed and blocked network interfaces.
These tests do not test Lightning payments or public-network synchronization.
Linux VM tests need KVM. CI runs the build and VM checks on x86_64 Linux.

## License

MIT or Apache-2.0, at your option. See [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE).
