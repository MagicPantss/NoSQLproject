#!/bin/bash
set -e

# Function to wait until MongoDB is available
wait_for_mongo() {
  host=$1; port=$2
  echo "Waiting for MongoDB at $host:$port..."
  until mongosh --host "$host" --port "$port" --eval "db.adminCommand({ ping: 1 })" &>/dev/null; do
    sleep 1
  done
  echo "$host:$port is up"
}

# 1) Inicializace config serverů
wait_for_mongo configsvr1 27019
mongosh --host configsvr1 --port 27019 <<EOF
rs.initiate({
  _id: "rs-config",
  configsvr: true,
  members: [
    { _id: 0, host: "configsvr1:27019" },
    { _id: 1, host: "configsvr2:27019" },
    { _id: 2, host: "configsvr3:27019" }
  ]
})
EOF

echo "Config replica set initialized"

# 2) Inicializace shard replikačních setů
for i in 1 2 3; do
  rs_name="rs-shard-0$i"
  primary_host="shard$i-a"
  wait_for_mongo "$primary_host" 27018
  mongosh --host "$primary_host" --port 27018 <<EOF
rs.initiate({
  _id: "$rs_name",
  members: [
    { _id: 0, host: "shard${i}-a:27018" },
    { _id: 1, host: "shard${i}-b:27018" },
    { _id: 2, host: "shard${i}-c:27018" }
  ]
})
EOF
  echo "$rs_name initialized"
done

# 3) Přidání shardů do clusteru
wait_for_mongo router 27017
mongosh --host router --port 27017 <<EOF
sh.addShard("rs-shard-01/shard1-a:27018,shard1-b:27018,shard1-c:27018");
sh.addShard("rs-shard-02/shard2-a:27018,shard2-b:27018,shard2-c:27018");
sh.addShard("rs-shard-03/shard3-a:27018,shard3-b:27018,shard3-c:27018");
EOF

echo "Shards added to cluster"

echo "Cluster initialization complete."