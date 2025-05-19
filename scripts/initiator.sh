#!/bin/bash

docker exec -it configsvr1 mongosh --port 27019 --eval '
rs.initiate({
  _id: "rs-config",
  members: [
    { _id: 0, host: "configsvr1:27019" },
    { _id: 1, host: "configsvr2:27019" },
    { _id: 2, host: "configsvr3:27019" }
  ]
});
'

echo "Let me sleep for 20 seconds"
sleep 20

docker exec -it router mongosh --eval 'db.getSiblingDB("admin").createUser({user: "admin", pwd: "password", roles: [{ role: "root", db: "admin" }]});'

echo "admin ucet admin/password"
echo "takhle se prihlas potom"
echo "docker exec -it router mongosh --authenticationDatabase admin -u admin -p password"
