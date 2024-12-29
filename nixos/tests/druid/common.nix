{
  pkgs,
  lib,
  hadoopPackage,
  druidPackage,
  ...
}:
let
  commonConfig = {
    "druid.zk.service.host" = "zk1:2181";
    "druid.extensions.loadList" =
      ''[ "druid-histogram", "druid-datasketches",  "mysql-metadata-storage", "druid-avro-extensions", "druid-parquet-extensions", "druid-lookups-cached-global", "druid-hdfs-storage","druid-kafka-indexing-service","druid-basic-security","druid-kinesis-indexing-service"]'';
    "druid.startup.logging.logProperties" = "true";
    "druid.metadata.storage.connector.connectURI" = "jdbc:mysql://mysql:3306/druid";
    "druid.metadata.storage.connector.user" = "druid";
    "druid.metadata.storage.connector.password" = "druid";
    "druid.request.logging.type" = "file";
    "druid.request.logging.dir" = "/var/log/druid/requests";
    "druid.javascript.enabled" = "true";
    "druid.sql.enable" = "true";
    "druid.metadata.storage.type" = "mysql";
    "druid.storage.type" = "hdfs";
    "druid.storage.storageDirectory" = "/druid-deepstore";
  };
  log4jConfig = ''
    <?xml version="1.0" encoding="UTF-8" ?>
    <Configuration status="WARN">
     <Appenders>
        <Console name="Console" target="SYSTEM_OUT">
          <PatternLayout pattern="%d{ISO8601} %p [%t] %c - %m%n"/>
        </Console>
      </Appenders>
      <Loggers>
        <Root level="error">
          <AppenderRef ref="Console"/>
        </Root>
      </Loggers>
    </Configuration>
  '';
  log4j = pkgs.writeText "log4j2.xml" log4jConfig;
  coreSite = {
    "fs.defaultFS" = "hdfs://namenode:8020";
  };
  hadoop_gateway_role = {
    hadoop = {
      gatewayRole.enable = true;
      package = hadoopPackage;
      inherit coreSite;
    };
  };
  druidCommonConfig = {
    inherit commonConfig log4j;
    package = druidPackage;
    extraClassPaths = [ "/etc/hadoop-conf" ];
  };
  druidCommonServiceConfig = {
    enable = true;
    openFirewall = true;
  };
in
{
  hadoop_init = ''
    namenode.wait_for_unit("hdfs-namenode")
    namenode.wait_for_unit("network.target")
    namenode.wait_for_open_port(8020)
    namenode.succeed("ss -tulpne | systemd-cat")
    namenode.succeed("cat /etc/hadoop*/hdfs-site.xml | systemd-cat")
    namenode.wait_for_open_port(9870)
    datanode.wait_for_unit("hdfs-datanode")
    datanode.wait_for_unit("network.target")
    namenode.succeed("sudo -u hdfs hdfs dfs -mkdir /druid-deepstore")
    namenode.succeed("HADOOP_USER_NAME=druid sudo -u hdfs hdfs dfs -chown druid:hadoop /druid-deepstore")
  '';
  create_data =
    service:
    lib.concatLines (
      map (line: "${service}.${line}") [
        ''succeed("mkdir -p /quickstart/") ''
        ''succeed("cp -r ${pkgs.druid}/quickstart/* /quickstart/") ''
        ''succeed("touch /quickstart/tutorial/wikiticker-2015-09-12-sampled.json") ''
        ''succeed("zcat /quickstart/tutorial/wikiticker-2015-09-12-sampled.json.gz | head -n 10 > /quickstart/tutorial/wikiticker-2015-09-12-sampled.json || true") ''
        ''succeed("rm /quickstart/tutorial/wikiticker-2015-09-12-sampled.json.gz && gzip /quickstart/tutorial/wikiticker-2015-09-12-sampled.json") ''
      ]
    );
  query_test = ''
    broker.succeed("curl -X 'POST' -H 'Content-Type:application/json' -d @${pkgs.druid}/quickstart/tutorial/wikipedia-index.json http://coordinator:9091/druid/indexer/v1/task")
    broker.wait_until_succeeds("curl http://coordinator:9091/druid/coordinator/v1/metadata/datasources | grep  'wikipedia'")
    broker.wait_until_succeeds("curl http://localhost:8082/druid/v2/datasources/ | grep wikipedia")
    broker.succeed("curl -X 'POST' -H 'Content-Type:application/json' -d @${pkgs.druid}/quickstart/tutorial/wikipedia-top-pages.json http://localhost:8082/druid/v2/")
  '';
  service_init = ''
    coordinator.wait_for_unit("druid-coordinator")
    overlord.wait_for_unit("druid-overlord")
    historical.wait_for_unit("druid-historical")

    coordinator.wait_for_open_port(9091)
    overlord.wait_for_open_port(8090)
    historical.wait_for_open_port(8083)

    broker.wait_for_unit("network.target")
    broker.wait_for_open_port(8082)
  '';
  nodes = {
    zk1 =
      { ... }:
      {
        services.zookeeper.enable = true;
        networking.firewall.allowedTCPPorts = [ 2181 ];
      };
    namenode =
      { ... }:
      {
        services.hadoop = {
          package = hadoopPackage;
          hdfs = {
            namenode = {
              enable = true;
              openFirewall = true;
              formatOnInit = true;
            };
          };
          inherit coreSite;
        };
      };
    datanode =
      { ... }:
      {
        services.hadoop = {
          package = hadoopPackage;
          hdfs.datanode = {
            enable = true;
            openFirewall = true;
          };
          inherit coreSite;
        };
      };
    mm =
      { ... }:
      {
        virtualisation.memorySize = 1024;
        services = {
          druid = {
            middleManager = {
              config = {
                "druid.indexer.task.baseTaskDir" = "/tmp/druid/persistent/task";
                "druid.worker.capacity" = 1;
                "druid.indexer.logs.type" = "file";
                "druid.indexer.logs.directory" = "/var/log/druid/indexer";
                "druid.indexer.runner.startPort" = 8100;
                "druid.indexer.runner.endPort" = 8101;
              };
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };
    indexer =
      { ... }:
      {
        virtualisation.memorySize = 1024;
        services = {
          druid = {
            indexer = {
              config = {
                "druid.indexer.task.baseTaskDir" = "/tmp/druid/persistent/task";
                "druid.worker.capacity" = 1;
                "druid.indexer.logs.type" = "file";
                "druid.indexer.logs.directory" = "/var/log/druid/indexer";
                "druid.indexer.runner.startPort" = 8100;
                "druid.indexer.runner.endPort" = 8101;
              };
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };
    overlord =
      { ... }:
      {
        services = {
          druid = {
            overlord = {
              config = {
                "druid.indexer.runner.type" = "remote";
                "druid.indexer.storage.type" = "metadata";
              };
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };
    broker =
      { ... }:
      {
        services = {
          druid = {
            broker = {
              config = {
                "druid.plaintextPort" = 8082;
                "druid.broker.http.numConnections" = "2";
                "druid.server.http.numThreads" = "2";
                "druid.processing.buffer.sizeBytes" = "100";
                "druid.processing.numThreads" = "1";
                "druid.processing.numMergeBuffers" = "1";
                "druid.broker.cache.unCacheable" = ''["groupBy"]'';
                "druid.lookup.snapshotWorkingDir" = "/opt/broker/lookups";
              };
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };
    historical =
      { ... }:
      {
        services = {
          druid = {
            historical = {
              config = {
                "maxSize" = 200000000;
                "druid.lookup.snapshotWorkingDir" = "/opt/historical/lookups";
              };
              segmentLocations = [
                {
                  "path" = "/tmp/1";
                  "maxSize" = "100000000";
                }
                {
                  "path" = "/tmp/2";
                  "maxSize" = "100000000";
                }
              ];
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };
    coordinator =
      { ... }:
      {
        services = {
          druid = {
            coordinator = {
              config = {
                "druid.plaintextPort" = 9091;
                "druid.service" = "coordinator";
                "druid.coordinator.startDelay" = "PT10S";
                "druid.coordinator.period" = "PT10S";
                "druid.manager.config.pollDuration" = "PT10S";
                "druid.manager.segments.pollDuration" = "PT10S";
                "druid.manager.rules.pollDuration" = "PT10S";
              };
            } // druidCommonServiceConfig;
          } // druidCommonConfig;
        } // hadoop_gateway_role;
      };

    mysql =
      { ... }:
      {
        services.mysql = {
          enable = true;
          package = pkgs.mariadb;
          initialDatabases = [ { name = "druid"; } ];
          initialScript = pkgs.writeText "mysql-init.sql" ''
            CREATE USER 'druid'@'%' IDENTIFIED BY 'druid';
            GRANT ALL PRIVILEGES ON druid.* TO 'druid'@'%';
          '';
        };
        networking.firewall.allowedTCPPorts = [ 3306 ];
      };

  };
}
