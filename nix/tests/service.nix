{ pkgs, ldkServerModule }:

{
  name = "ldk-server-service";

  nodes.machine = { config, lib, ... }: {
    imports = [ ldkServerModule ];
    virtualisation = {
      memorySize = 2048;
      vlans = [
        1
        2
      ];
    };
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.1.10";
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.2.10";
        prefixLength = 24;
      }
    ];

    services.bitcoind.regtest = {
      enable = true;
      configFile = pkgs.writeText "bitcoin-regtest.conf" ''
        regtest=1
        server=1
        listen=0
        rpcuser=test
        rpcpassword=test-only-password
        fallbackfee=0.0002
      '';
    };
    environment.etc."ldk-server-test.env".text = ''
      LDK_SERVER_BITCOIND_RPC_USER=test
      LDK_SERVER_BITCOIND_RPC_PASSWORD=test-only-password
    '';
    services.ldk-server.instances.regtest = {
      enable = true;
      openFirewall = true;
      firewallInterfaces = [ "eth1" ];
      environmentFiles = [ "/etc/ldk-server-test.env" ];
      settings = {
        node.network = "regtest";
        bitcoind.rpc_address = "127.0.0.1:18443";
        log.log_to_file = false;
      };
    };
    systemd.services.ldk-server-regtest = {
      requires = [ "bitcoind-regtest.service" ];
      after = [ "bitcoind-regtest.service" ];
    };
    environment.systemPackages = [ config.services.ldk-server.package ];
  };

  nodes.allowed = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.netcat ];
  };
  nodes.denied = {
    virtualisation.vlans = [ 2 ];
    environment.systemPackages = [ pkgs.netcat ];
  };

  testScript = ''
    import json

    start_all()
    machine.wait_for_unit("ldk-server-regtest.service", timeout=180)
    allowed.wait_for_unit("multi-user.target")
    denied.wait_for_unit("multi-user.target")
    allowed.wait_until_succeeds("ping -c 1 -W 3 192.168.1.10", timeout=30)
    denied.wait_until_succeeds("ping -c 1 -W 3 192.168.2.10", timeout=30)
    allowed.succeed("nc -z -w 3 192.168.1.10 9735")
    denied.fail("nc -z -w 3 192.168.2.10 9735")
    allowed.fail("nc -z -w 3 192.168.1.10 3536")

    base = "/var/lib/ldk-server/regtest"
    cli = (
        f"ldk-server-cli --base-url 127.0.0.1:3536 "
        f"--tls-cert {base}/tls.crt "
        f"--macaroon $(cat {base}/regtest/macaroons/admin.macaroon) "
        "get-node-info"
    )
    info = json.loads(machine.succeed(cli))
    assert info, info
    machine.succeed(f"test -s {base}/keys_mnemonic")
    machine.succeed("systemctl stop ldk-server-regtest.service")
    assert machine.succeed("systemctl show ldk-server-regtest -p Result --value").strip() == "success"
    machine.succeed("systemctl is-active --quiet bitcoind-regtest.service")
    machine.succeed("systemctl start ldk-server-regtest.service")
    machine.wait_for_unit("ldk-server-regtest.service", timeout=180)
    restarted = json.loads(machine.succeed(cli))
    assert restarted["node_id"] == info["node_id"], (info, restarted)
  '';
}
