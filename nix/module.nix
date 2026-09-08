{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.services.ldk-server;
  toml = pkgs.formats.toml { };

  isAbsolutePath = path: lib.hasPrefix "/" path;
  isAbsoluteEnvironmentFile = path: isAbsolutePath (lib.removePrefix "-" path);

  instanceType = types.submodule (
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Start this LDK Server instance.";
        };

        settings = mkOption {
          inherit (toml) type;
          default = { };
          example = lib.literalExpression ''
            {
              node = {
                network = "bitcoin";
                listening_addresses = [ "0.0.0.0:9735" ];
              };
              esplora.server_url = "https://mempool.space/api";
            }
          '';
          description = ''
            Settings for the generated TOML file. Do not put secrets in this
            option because the Nix store is readable by all local users.
          '';
        };

        configFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            An existing TOML configuration file with an absolute path. This
            option and settings cannot be used together.
          '';
        };

        environmentFiles = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/run/secrets/ldk-server-${name}" ];
          description = ''
            Files with environment variables for secrets and setting
            overrides. Each file must have an absolute path and use systemd
            EnvironmentFile syntax. Prefix a path with - to make it optional.
          '';
        };

        dataDir = mkOption {
          type = types.str;
          default = "/var/lib/ldk-server/${name}";
          description = ''
            The absolute path of the directory that stores data for this
            instance.
          '';
        };

        user = mkOption {
          type = types.str;
          default = "ldk-server-${name}";
          description = "The user for this instance.";
        };

        group = mkOption {
          type = types.str;
          default = "ldk-server-${name}";
          description = "The group for this instance.";
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open the selected ports on firewallInterfaces for this instance.";
        };

        firewallInterfaces = mkOption {
          type = types.listOf (
            types.addCheck types.str (interface: interface != "" && interface != "default")
          );
          default = [ ];
          example = [ "wg0" ];
          description = ''
            Interfaces on which to open the selected ports when openFirewall
            is enabled. An empty list opens them on all interfaces. This
            option does not change the server's listening addresses.
            Names must be nonempty and cannot be the NixOS-reserved name
            "default".
          '';
        };

        lightningPort = mkOption {
          type = types.nullOr types.port;
          default = 9735;
          description = ''
            The default Lightning listener port and the port to open when
            openFirewall is enabled. Generated configuration listens on
            0.0.0.0 at this port unless settings.node.listening_addresses
            is set. An explicit listener or configFile must use the same
            port if openFirewall is enabled. Set null to omit the generated
            listener default and the Lightning firewall rule.
          '';
        };

        grpcPort = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = ''
            The gRPC port to open. This port must match the instance
            configuration.
          '';
        };
      };
    }
  );

  enabledInstances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;

  generatedConfigs = lib.mapAttrs (
    name: instance:
    let
      defaults = {
        node = {
          grpc_service_address = "127.0.0.1:3536";
        }
        // lib.optionalAttrs (instance.lightningPort != null) {
          listening_addresses = [ "0.0.0.0:${toString instance.lightningPort}" ];
        };
      };
    in
    toml.generate "ldk-server-${name}.toml" (
      lib.recursiveUpdate (lib.recursiveUpdate defaults instance.settings) {
        storage.disk.dir_path = instance.dataDir;
      }
    )
  ) enabledInstances;

  instanceConfigPath =
    name: instance:
    if instance.configFile == null then generatedConfigs.${name} else instance.configFile;

  defaultUsers = lib.filterAttrs (
    name: instance: instance.user == "ldk-server-${name}"
  ) enabledInstances;
  defaultGroups = lib.filterAttrs (
    name: instance: instance.group == "ldk-server-${name}"
  ) enabledInstances;
in
{
  options.services.ldk-server = {
    package = mkOption {
      type = types.package;
      description = "The LDK Server package to run. The flake module supplies the default.";
    };

    instances = mkOption {
      type = types.attrsOf instanceType;
      default = { };
      description = "Named LDK Server instances.";
    };
  };

  config = {
    assertions =
      lib.concatLists (
        lib.mapAttrsToList (name: instance: [
          {
            assertion = builtins.match "^[a-zA-Z0-9_-]+$" name != null;
            message = "LDK Server instance name '${name}' contains invalid characters";
          }
          {
            assertion = instance.configFile == null || instance.settings == { };
            message = ''
              services.ldk-server.instances.${name}.configFile and settings
              cannot be used together
            '';
          }
          {
            assertion = isAbsolutePath instance.dataDir;
            message = ''
              services.ldk-server.instances.${name}.dataDir must be an
              absolute path
            '';
          }
          {
            assertion = instance.configFile == null || isAbsolutePath instance.configFile;
            message = ''
              services.ldk-server.instances.${name}.configFile must be an
              absolute path
            '';
          }
          {
            assertion = lib.all isAbsoluteEnvironmentFile instance.environmentFiles;
            message = ''
              services.ldk-server.instances.${name}.environmentFiles must
              contain absolute paths
            '';
          }
          {
            assertion = !instance.openFirewall || instance.lightningPort != null || instance.grpcPort != null;
            message = ''
              services.ldk-server.instances.${name}.openFirewall requires at
              least one port
            '';
          }
        ]) enabledInstances
      )
      ++ [
        {
          assertion =
            builtins.length (lib.unique (lib.mapAttrsToList (_: instance: instance.dataDir) enabledInstances))
            == builtins.length (lib.attrNames enabledInstances);
          message = "Enabled LDK Server instances must use different data directories";
        }
      ];

    users.groups = lib.mapAttrs' (_: instance: lib.nameValuePair instance.group { }) defaultGroups;

    users.users = lib.mapAttrs' (
      _: instance:
      lib.nameValuePair instance.user {
        isSystemUser = true;
        group = instance.group;
        home = instance.dataDir;
      }
    ) defaultUsers;

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _: instance: "d '${instance.dataDir}' 0750 ${instance.user} ${instance.group} - -"
    ) enabledInstances;

    systemd.services = lib.mapAttrs' (
      name: instance:
      lib.nameValuePair "ldk-server-${name}" {
        description = "LDK Server Lightning Node (${name})";
        documentation = [ "https://github.com/lightningdevkit/ldk-server" ];
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        serviceConfig = {
          Type = "notify";
          NotifyAccess = "main";
          ExecStart = lib.escapeShellArgs [
            (lib.getExe cfg.package)
            (instanceConfigPath name instance)
            "--storage-dir-path"
            instance.dataDir
          ];
          User = instance.user;
          Group = instance.group;
          EnvironmentFile = instance.environmentFiles;
          Restart = "on-failure";
          RestartSec = 10;

          # Allow initial synchronization and graceful state persistence.
          # Hosts can change these defaults through systemd.services.
          TimeoutStartSec = lib.mkDefault "20min";
          TimeoutStopSec = lib.mkDefault "1h";

          UMask = lib.mkDefault "0077";
          AmbientCapabilities = lib.mkDefault [ ];
          CapabilityBoundingSet = lib.mkDefault [ ];
          LockPersonality = lib.mkDefault true;
          NoNewPrivileges = lib.mkDefault true;
          PrivateDevices = lib.mkDefault true;
          PrivateTmp = lib.mkDefault true;
          ProtectClock = lib.mkDefault true;
          ProtectControlGroups = lib.mkDefault true;
          ProtectHome = lib.mkDefault true;
          ProtectHostname = lib.mkDefault true;
          ProtectKernelLogs = lib.mkDefault true;
          ProtectKernelModules = lib.mkDefault true;
          ProtectKernelTunables = lib.mkDefault true;
          ProtectSystem = lib.mkDefault "strict";
          ReadWritePaths = [ instance.dataDir ];
          RestrictAddressFamilies = lib.mkDefault [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = lib.mkDefault true;
          RestrictRealtime = lib.mkDefault true;
          RestrictSUIDSGID = lib.mkDefault true;
        };
      }
    ) enabledInstances;

    networking.firewall = lib.mkMerge (
      lib.mapAttrsToList (
        _: instance:
        let
          ports = lib.filter (port: port != null) [
            instance.lightningPort
            instance.grpcPort
          ];
        in
        if instance.firewallInterfaces == [ ] then
          { allowedTCPPorts = ports; }
        else
          {
            interfaces = lib.genAttrs instance.firewallInterfaces (_: {
              allowedTCPPorts = ports;
            });
          }
      ) (lib.filterAttrs (_: instance: instance.openFirewall) enabledInstances)
    );
  };
}
