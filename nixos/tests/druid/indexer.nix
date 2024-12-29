{ pkgs, ... }:
let
  inherit (pkgs) lib;
  tests = {
    default = testsForPackage {
      druidPackage = pkgs.druid;
      hadoopPackage = pkgs.hadoop_3_3;
    };
  };
  testsForPackage =
    args:
    lib.recurseIntoAttrs {
      druidCluster = testDruidCluster args;
      passthru.override = args': testsForPackage (args // args');
    };
  testDruidCluster =
    { druidPackage, hadoopPackage, ... }:
    let
      common = import ./common.nix {
        inherit
          pkgs
          lib
          hadoopPackage
          druidPackage
          ;
      };
    in
    pkgs.testers.nixosTest rec {
      name = "druid-hdfs-indexer";
      nodes = lib.filterAttrs (service: _: service != "mm") common.nodes;
      testScript = lib.concatLines (
        with common;
        [
          "start_all()"
          hadoop_init
          (create_data "indexer")
          service_init
          ''
            mm.wait_for_unit("druid-indexer")
            mm.wait_for_open_port(8091)
          ''
          query_test
        ]
      );

    };
in
tests
