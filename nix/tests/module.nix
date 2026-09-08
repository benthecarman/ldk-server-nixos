{ pkgs, ldkServerModule }:

let
  fakeServer = pkgs.writeShellApplication {
    name = "ldk-server";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      config_file="$1"
      test "$2" = "--storage-dir-path"
      data_dir="$3"

      cp --remove-destination "$config_file" "$data_dir/observed-config.toml"
      printf '%s\n' "$@" > "$data_dir/observed-arguments"
      printf '%s\n' "''${LDK_SERVER_TEST_SECRET:-unset}" > "$data_dir/observed-secret"
      exec systemd-notify --ready --exec ';' sleep infinity
    '';
  };
in
{
  name = "ldk-server-module";

  nodes.machine = {
    imports = [ ldkServerModule ];

    environment.etc."ldk-server-test.env".text = "LDK_SERVER_TEST_SECRET=test-only-secret\n";
    environment.etc."ldk-server-external.toml".text = ''
      [node]
      network = "regtest"
      [storage.disk]
      dir_path = "/ignored-storage-path"
    '';

    services.ldk-server = {
      package = fakeServer;
      instances = {
        mainnet = {
          enable = true;
          environmentFiles = [
            "/etc/ldk-server-test.env"
            "-/run/secrets/ldk-server-mainnet"
          ];
          settings.node.network = "bitcoin";
          settings.storage.disk.dir_path = "/ignored-storage-path";
          openFirewall = true;
        };
        signet = {
          enable = true;
          dataDir = "/var/lib/ldk-server-signet-test";
          settings.node.network = "signet";
          lightningPort = 39735;
          grpcPort = 13536;
        };
        custom = {
          enable = true;
          lightningPort = 8735;
          openFirewall = true;
          settings.node.listening_addresses = [ "127.0.0.1:8735" ];
        };
        external = {
          enable = true;
          configFile = "/etc/ldk-server-external.toml";
        };
        disabled = {
          enable = false;
          openFirewall = true;
          lightningPort = 29735;
        };
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("ldk-server-mainnet.service")
    machine.wait_for_unit("ldk-server-signet.service")
    machine.wait_for_unit("ldk-server-external.service")
    machine.wait_for_unit("ldk-server-custom.service")

    import tomllib

    for instance, data_dir, listener in [
        ("mainnet", "/var/lib/ldk-server/mainnet", "0.0.0.0:9735"),
        ("signet", "/var/lib/ldk-server-signet-test", "0.0.0.0:39735"),
        ("custom", "/var/lib/ldk-server/custom", "127.0.0.1:8735"),
    ]:
        observed = tomllib.loads(machine.succeed(f"cat {data_dir}/observed-config.toml"))
        assert observed["node"]["listening_addresses"] == [listener], instance

    machine.succeed(
      "test $(stat -c '%U:%G:%a' /var/lib/ldk-server/mainnet) = "
      "ldk-server-mainnet:ldk-server-mainnet:750"
    )
    machine.succeed(
      "test $(stat -c '%U:%G:%a' /var/lib/ldk-server-signet-test) = "
      "ldk-server-signet:ldk-server-signet:750"
    )

    machine.succeed(
      "grep -F 'network = \"bitcoin\"' "
      "/var/lib/ldk-server/mainnet/observed-config.toml"
    )
    machine.succeed(
      "grep -F 'dir_path = \"/var/lib/ldk-server/mainnet\"' "
      "/var/lib/ldk-server/mainnet/observed-config.toml"
    )
    machine.succeed(
      "grep -F 'network = \"signet\"' "
      "/var/lib/ldk-server-signet-test/observed-config.toml"
    )
    machine.succeed(
      "grep -F 'dir_path = \"/var/lib/ldk-server-signet-test\"' "
      "/var/lib/ldk-server-signet-test/observed-config.toml"
    )

    machine.succeed("grep -Fx test-only-secret /var/lib/ldk-server/mainnet/observed-secret")
    machine.succeed("grep -Fx unset /var/lib/ldk-server-signet-test/observed-secret")
    machine.succeed(
      "cmp /etc/ldk-server-external.toml "
      "/var/lib/ldk-server/external/observed-config.toml"
    )
    machine.succeed(
      "printf '%s\\n' /etc/ldk-server-external.toml --storage-dir-path "
      "/var/lib/ldk-server/external | "
      "cmp - /var/lib/ldk-server/external/observed-arguments"
    )
    machine.fail("id ldk-server-disabled")
    machine.fail("test -e /var/lib/ldk-server/disabled")
    machine.fail("systemctl cat ldk-server-disabled.service")
    machine.fail(
      "su -s /bin/sh ldk-server-signet -c "
      "'cat /var/lib/ldk-server/mainnet/observed-secret'"
    )
    machine.succeed("iptables -S nixos-fw | grep -- '--dport 9735 -j nixos-fw-accept'")
    machine.succeed("iptables -S nixos-fw | grep -- '--dport 8735 -j nixos-fw-accept'")
    machine.fail("iptables -S nixos-fw | grep -- '--dport 39735 '")
    machine.fail("iptables -S nixos-fw | grep -- '--dport 13536 '")
    machine.fail("iptables -S nixos-fw | grep -- '--dport 29735 '")

    machine.succeed("systemctl stop ldk-server-mainnet.service")
    machine.fail("systemctl is-active --quiet ldk-server-mainnet.service")
    machine.succeed("systemctl is-active --quiet ldk-server-signet.service")
  '';
}
