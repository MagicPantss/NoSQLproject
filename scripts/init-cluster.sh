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

#wait_for_mongo router 27017


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


# 4) Vytvoření userů
mongosh --host router --port 27017 <<EOF
use ProjectDatabase

db.getSiblingDB("admin").createUser({user: "admin", pwd: "password", roles: [{ role: "root", db: "admin" }]});

EOF

echo "Users created"

# 5) Vytváření a kolekcí a validační schéma

wait_for_port router 27017
echo "--- Importing CSV into netflix_raw ---"
mongoimport \
  --host router --port 27017 \
  --username admin --password password \
  --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection netflix_raw \
  --type csv \
  --file /data/netflix_titles.csv \
  --headerline

echo "CSV imported into netflix_raw"

wait_for_port router 27017

echo "--- Importing StudentsPerformance.csv into students_raw ---"
mongoimport \
  --host router --port 27017 \
  --username admin --password password \
  --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection students_raw \
  --type csv \
  --file /data/StudentsPerformance.csv \
  --headerline

echo "StudentsPerformance.csv imported into students_raw"

wait_for_port router 27017

echo "--- Importing insurance.csv into medical_raw ---"
mongoimport \
  --host router --port 27017 \
  --username admin --password password \
  --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection medical_raw \
  --type csv \
  --file /data/insurance.csv \
  --headerline

echo "insurance.csv imported into medical_raw"


wait_for_mongo router 27017
mongosh --host router --port 27017 \
  --username admin --password password \
  --authenticationDatabase admin <<EOF
use ProjectDatabase

db.createCollection("netflix", {
  validator: { \$jsonSchema: {
    bsonType: "object",
    required: ["show_id","type","title","release_year"],
    properties: {
      _id:          { bsonType: "objectId" },
      show_id:      { bsonType: "string" },
      type:         { enum: ["Movie","TV Show"] },
      title:        { bsonType: "string" },
      director:     { bsonType: ["string","null"] },
      cast:         { bsonType: ["string","null"] },
      country:      { bsonType: ["string","null"] },
      date_added:   { bsonType: ["date","null"] },
      release_year: { bsonType: ["int"], description: "rok jako číslo" },
      rating:       { bsonType: ["string","null"] },
      duration:     { bsonType: ["string","null"] },
      listed_in:    { bsonType: ["array"], items: { bsonType: "string" } },
      description:  { bsonType: "string" }
    },
    additionalProperties: false
  }},
  validationLevel: "strict",
  validationAction: "error"
});

db.netflix_raw.aggregate([
  {
    \$addFields: {
      show_id:       { \$toString: "\$show_id" },
      title:         { \$toString: "\$title" },
      date_added: {
        \$cond: [
          { \$or: [ { \$eq: ["\$date_added", null] }, { \$eq: ["\$date_added", ""] } ] },
          null,
          { \$toDate: "\$date_added" }
        ]
      },
      release_year: {
        \$cond: [
          { \$or: [ { \$eq: ["\$release_year", null] }, { \$eq: ["\$release_year", ""] } ] },
          null,
          { \$toInt: "\$release_year" }
        ]
      },
      listed_in: {
        \$cond: [
          { \$or: [ { \$eq: ["\$listed_in", null] }, { \$eq: ["\$listed_in", ""] } ] },
          [],
          { \$split: ["\$listed_in", ", "] }
        ]
      }
    }
  },
  { \$out: "netflix" }
], { allowDiskUse: true });

print("Imported documents:", db.netflix.count());

db.createCollection("students", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["gender","parental level of education","math score","reading score","writing score"],
      properties: {
	_id: { bsonType: "objectId", description: "automaticky MongoDB vytvořený klíč" },
        gender: { enum: ["male","female"] },
        "parental level of education": { bsonType: "string" },
        "race/ethnicity": { bsonType: "string" },
        lunch: { bsonType: "string", description: "type of lunch" },
        "test preparation course": { bsonType: "string" },
        "math score": { bsonType: "int", minimum: 0, maximum: 100 },
        "reading score": { bsonType: "int", minimum: 0, maximum: 100 },
        "writing score": { bsonType: "int", minimum: 0, maximum: 100 }
      },
      additionalProperties: false
    }
  },
  validationLevel: "strict",
  validationAction: "error"
})

db.students_raw.aggregate([
  {
    \$addFields: {
      "math score":    { \$toInt: "\$math score" },
      "reading score": { \$toInt: "\$reading score" },
      "writing score": { \$toInt: "\$writing score" }
    }
  },
  { \$out: "students" }
], { allowDiskUse: true })

print("Imported documents:", db.students.count());

db.createCollection("medical_cost", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["age","sex","bmi","charges"],
      properties: {
        _id: { bsonType: "objectId" },
        age: { bsonType: "int", minimum: 0 },
        sex: { enum: ["male","female"] },
        bmi: { bsonType: "double", minimum: 0, description: "body-mass index" },
        children: { bsonType: "int", minimum: 0, description: "number of children" },
        smoker: { enum: ["yes","no"] },
        region: { bsonType: "string", description: "region of living" },
        charges: { bsonType: "double", minimum: 0, description: "costs billed" }
      },
      additionalProperties: false
    }
  },
  validationLevel: "strict",
  validationAction: "error"
})

db.medical_raw.aggregate([
  {
    \$addFields: {
      age:      { \$toInt:    "\$age" },
      bmi:      { \$toDouble: "\$bmi" },
      children: { \$toInt:    "\$children" },
      charges:  { \$toDouble: "\$charges" }
    }
  },
  { \$out: "medical_cost" }
], { allowDiskUse: true })

print("Imported documents:", db.medical_cost.count());

EOF

echo "Data sent form _raw to correct format"

# 6) Zapnutí shardingu a rozdělení kolekcí

wait_for_mongo router 27017
mongosh --host router --port 27017 \
  --username admin --password password \
  --authenticationDatabase admin <<EOF
use ProjectDatabase

sh.enableSharding("ProjectDatabase")

// 1) Netflix podle show_id
db.netflix.createIndex({ show_id: 1 })
sh.shardCollection("ProjectDatabase.netflix", { show_id: 1 })

// 2) Students podle _id hashed
// Mongo už má výchozí index { _id: 1 }, ale pro hashed musíme explicitně vytvořit hashed index:
db.students.createIndex({ _id: "hashed" })
sh.shardCollection("ProjectDatabase.students", { _id: "hashed" })

// 3) Medical_cost podle _id hashed
db.medical_cost.createIndex({ _id: "hashed" })
sh.shardCollection("ProjectDatabase.medical_cost", { _id: "hashed" })

EOF

echo "Collections sharded"
echo "Cluster initialization complete."