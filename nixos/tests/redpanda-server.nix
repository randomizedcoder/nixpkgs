# Single-node broker started from an inline unit (there is no NixOS module
# yet); exercises the admin API and a Kafka produce/consume round trip
# with rpk.
{ lib, pkgs, ... }:
let
  redpandaYaml = pkgs.writeText "redpanda.yaml" ''
    redpanda:
      data_directory: /var/lib/redpanda/data
      developer_mode: true
      node_id: 0
      empty_seed_starts_cluster: true
      seed_servers: []
      rpc_server:
        address: 127.0.0.1
        port: 33145
      kafka_api:
        - address: 127.0.0.1
          port: 9092
      admin:
        - address: 127.0.0.1
          port: 9644
    pandaproxy: {}
    schema_registry: {}
  '';
  rpk = "${lib.getExe pkgs.redpanda-client} -X brokers=127.0.0.1:9092 -X admin.hosts=127.0.0.1:9644";
in
{
  name = "redpanda-server";
  meta.maintainers = with lib.maintainers; [ randomizedcoder ];

  # Both the broker and rpk are unfree; the node has to be able to set
  # nixpkgs.config.allowUnfreePackages.
  node.pkgsReadOnly = false;

  nodes.server =
    { pkgs, ... }:
    {
      nixpkgs.config.allowUnfreePackages = [
        "redpanda-server"
        "redpanda-rpk"
      ];

      virtualisation.memorySize = 3072;
      # The broker reports the node as low on disk, and the cluster as
      # unhealthy, while free space is under storage_min_free_bytes (5 GiB).
      virtualisation.diskSize = 10240;

      environment.systemPackages = [
        pkgs.redpanda-client
        pkgs.jq
      ];

      systemd.services.redpanda = {
        description = "Redpanda broker";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            (lib.getExe pkgs.redpanda-server)
            "--redpanda-cfg ${redpandaYaml}"
            # Small, VM-friendly footprint.
            "--smp 1"
            "--memory 1G"
            "--reserve-memory 0M"
            "--overprovisioned"
          ];
          DynamicUser = true;
          StateDirectory = "redpanda";
          LimitNOFILE = 65536;
        };
      };
    };

  testScript = # python
    ''
      import re
      from datetime import timedelta

      start_all()
      server.wait_for_unit("redpanda.service")
      server.wait_for_open_port(9644, "127.0.0.1")
      server.wait_until_succeeds(
          "curl -sf http://127.0.0.1:9644/v1/cluster/health_overview | jq -e .is_healthy",
          timeout=timedelta(minutes=2),
      )
      server.wait_for_open_port(9092, "127.0.0.1")

      with subtest("cluster info"):
          out = server.succeed("${rpk} cluster info")
          # Broker table row: `0*    127.0.0.1  9092`
          assert re.search(r"^0\*?\s+127\.0\.0\.1\s+9092$", out, re.M), out

      with subtest("produce and consume"):
          server.succeed("${rpk} topic create nixos-test")
          server.succeed("echo hello-from-nixos | ${rpk} topic produce nixos-test")
          out = server.succeed("${rpk} topic consume nixos-test --num 1 --offset start")
          assert "hello-from-nixos" in out, out
    '';
}
