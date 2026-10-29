# NixOS integration

The module supplies the daemon, separate instance users and state directories,
and service defaults. The host selects its chain backend, network access,
and secret provider.

## Network access

No firewall ports open by default. Generated configuration listens for
Lightning peers on `0.0.0.0:9735` and serves gRPC on `127.0.0.1:3536`.
Both listeners can be changed through `settings.node`; `lightningPort` sets
the default Lightning listener port.

To admit Lightning connections only through selected interfaces:

```nix
services.ldk-server.instances.mainnet = {
  enable = true;
  openFirewall = true;
  firewallInterfaces = [ "wg0" ];
};
```

Replace `wg0` with the interface names on your host. You can list more than
one interface. With `openFirewall = true`, an empty `firewallInterfaces`
list opens the selected ports on all interfaces. With `openFirewall = false`,
the module adds no firewall rules, regardless of the interface list.

Firewall rules do not change listening addresses. Other host firewall rules
can also grant access, so check the combined configuration. In particular,
another service that opens the same port globally makes that port accessible
on other interfaces too.

For an instance that only accepts local connections:

```nix
services.ldk-server.instances.signet = {
  enable = true;
  lightningPort = 39735;
  settings.node = {
    network = "signet";
    listening_addresses = [ "127.0.0.1:39735" ];
    grpc_service_address = "127.0.0.1:13536";
  };
};
```

These snippets show network settings; each instance also needs a chain
backend. When you change explicit listener addresses, keep their ports
aligned with `lightningPort` and `grpcPort` if you open the firewall.
`grpcPort` only selects a firewall port; it does not change the gRPC listener.
A complete `configFile` supplies its own listener settings.

Keep gRPC on loopback for local clients or use an SSH tunnel. To expose it
on a private network, explicitly set its bind address, `grpcPort`, and allowed
interfaces, and configure TLS for that address. See the upstream
[TLS guide](https://github.com/lightningdevkit/ldk-server/blob/main/docs/operations.md#tls).

## Local service dependencies

The module waits for `network-online.target`. It does not assume that Bitcoin
Core or Tor runs on the same machine. Esplora, Electrum, and remote Bitcoin
Core setups do not need a local Bitcoin service dependency.

For a local Bitcoin Core instance named `main`, add normal NixOS unit options:

```nix
{
  services.ldk-server.instances.mainnet.settings.bitcoind.rpc_address =
    "127.0.0.1:8332";

  systemd.services.ldk-server-mainnet = {
    requires = [ "bitcoind-main.service" ];
    after = [ "bitcoind-main.service" ];
  };
}
```

Supply RPC credentials through a runtime file as described below. Select
exactly one chain backend: remove Esplora or Electrum settings when you select
Bitcoin Core. For signet, use the matching unit name and RPC port on your host.

`after` orders startup; it does not start the dependency. `requires` starts
the dependency and stops or restarts LDK when that dependency is explicitly
stopped or restarted. Starting a stopped dependency again does not automatically
restart a stopped dependent service. If you
prefer the LDK service to retry while the backend is unavailable, use `wants`
instead of `requires`. Service ordering also does not guarantee that a backend
has completed chain synchronization.

If you configure a local Tor proxy, add `tor.service` to `after` and `wants`.
Binding a VPN address may also need a readiness check for that address;
ordering after the VPN service alone does not guarantee it has been assigned.
These choices belong in the host configuration.

## Timeouts and service hardening

The module allows 20 minutes for startup and one hour for graceful shutdown.
It restarts the daemon after failures. Files created by the service use a
`0077` umask. The service has no Linux capabilities and restricts filesystem
writes, device access, kernel changes, namespace creation, and privilege gains.

Timeouts and hardening settings are Nix defaults. You can override them with
normal `systemd.services` options, without `lib.mkForce`:

```nix
systemd.services.ldk-server-mainnet.serviceConfig = {
  TimeoutStartSec = "30min";
  TimeoutStopSec = "2h";
};
```

Use a larger startup timeout for slow synchronization or storage. Shutdown
needs time to persist node state. If a custom configuration writes outside
`dataDir`, add only those directories to `serviceConfig.ReadWritePaths`.

## Memory use

The module sets `MALLOC_ARENA_MAX=2` for each instance. glibc gives each
busy thread its own allocation arena and keeps freed memory in it. Without a
limit, the daemon's resident size can grow to several times its live heap.
Set `mallocArenaMax` to another value, or to `null` for the glibc default.

Tokio starts one worker thread for each CPU core. On a host with many cores,
set `workerThreads` to use fewer workers and less memory:

```nix
services.ldk-server.instances.mainnet = {
  mallocArenaMax = 2;
  workerThreads = 4;
};
```

Variables in `environmentFiles` override these values.

## Runtime secrets

`settings` is stored in the Nix store and must not contain secrets.
`environmentFiles` accepts systemd environment files from any provider.
Systemd reads these files before dropping privileges, so they can be owned by
root with mode `0400`. A leading `-` makes a file optional; required credential
files should normally omit it.

The decrypted file must use systemd EnvironmentFile syntax, for example:

```text
LDK_SERVER_BITCOIND_RPC_USER=ldk
LDK_SERVER_BITCOIND_RPC_PASSWORD=example-only-password
```

Use a separate file for each instance when credentials differ. When a runtime
file changes, restart the affected service to load the new values. Nix cannot
detect a content change from an unchanged runtime path alone.

### SOPS example

First configure [sops-nix](https://github.com/Mic92/sops-nix) in your host
flake, including its decryption identity. Store the complete environment file
above as an encrypted SOPS dotenv file in your configuration repository.
Then declare it in a host module:

```nix
{ config, ... }: {
  sops.secrets."ldk-server-mainnet.env" = {
    sopsFile = ./secrets/ldk-server-mainnet.env;
    format = "dotenv";
    key = ""; # Decrypt the complete environment file.
    mode = "0400";
    restartUnits = [ "ldk-server-mainnet.service" ];
  };

  services.ldk-server.instances.mainnet.environmentFiles = [
    config.sops.secrets."ldk-server-mainnet.env".path
  ];
}
```

SOPS restarts the listed unit when the secret changes during activation.
This flake does not import or depend on sops-nix. An agenix-managed environment
file or another runtime secret provider can use the same `environmentFiles`
option; configure its own service restart handling.

For a complete TOML configuration, use `configFile` instead. Its runtime file
must be readable by the instance user because the daemon reads it directly.
You can also use systemd `LoadCredential` through normal unit options and set
`configFile` to the corresponding `/run/credentials/<unit>/<credential>` path.
