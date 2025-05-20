#!/bin/bash

docker exec -it configsvr1 mongosh --port 27019 --eval '
rs.initiate({
  _id: "rs-config",
  configsvr: true,
  members: [
    { _id: 0, host: "configsvr1:27019" },
    { _id: 1, host: "configsvr2:27019" },
    { _id: 2, host: "configsvr3:27019" }
  ]
});
'

echo "Let me sleep for 20 seconds"
sleep 5

echo "admin ucet admin/password"
echo "takhle se prihlas potom"
echo "docker exec -it router mongosh --authenticationDatabase admin -u admin -p password"

echo "Config replica set initialized"

# 2) Inicializace shard replikačních setů
for i in 1 2 3; do
  echo "Initializing rs-shard-0$i…"
  docker exec shard${i}-a mongosh --port 27018 --eval "
    rs.initiate({
      _id: 'rs-shard-0$i',
      members: [
        { _id: 0, host: 'shard${i}-a:27018' },
        { _id: 1, host: 'shard${i}-b:27018' },
        { _id: 2, host: 'shard${i}-c:27018' }
      ]
    });
  "
  echo "✔ rs-shard-0$i initialized"
done
sleep 20

docker exec -it router mongosh --eval 'db.getSiblingDB("admin").createUser({user: "admin", pwd: "password", roles: [{ role: "root", db: "admin" }]});'


echo "Users created"

sleep 20


for i in 1 2 3; do
  echo "Adding rs-shard-0$i into cluster…"
  docker exec -it router mongosh \
    -u admin -p password --authenticationDatabase admin \
    --eval "sh.addShard('rs-shard-0$i/shard${i}-a:27018,shard${i}-b:27018,shard${i}-c:27018')"
done

# Ověření:
docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval "printjson(sh.status())"

echo "SEM BY TO MELO FUNGOVAT"

sleep 20


# 5) Vytváření a kolekcí a validační schéma

echo "--- Importing CSV into netflix_raw ---"
docker exec router mongoimport \
  -u admin -p password --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection netflix_raw \
  --type csv \
  --headerline \
  --file /data/netflix_titles.csv
echo "✔ netflix_raw imported"

echo "--- Importing StudentsPerformance.csv into students_raw ---"
docker exec router mongoimport \
  -u admin -p password --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection students_raw \
  --type csv \
  --headerline \
  --file /data/StudentsPerformance.csv
echo "✔ students_raw imported"

echo "--- Importing insurance.csv into medical_raw ---"
docker exec router mongoimport \
  -u admin -p password --authenticationDatabase admin \
  --db ProjectDatabase \
  --collection medical_raw \
  --type csv \
  --headerline \
  --file /data/insurance.csv
echo "✔ medical_raw imported"

sleep 10

docker exec -it router mongosh --authenticationDatabase admin -u admin -p password --eval 'db.getSiblingDB("ProjectDatabase").netflix.insertOne({ test: "data" });'

 docker exec -it router mongosh \
    -u admin -p password --authenticationDatabase admin \
    --eval '
use ProjectDatabase

db.createCollection("netflix", {
  validator: { $jsonSchema: {
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
    $addFields: {
      show_id:       { $toString: "$show_id" },
      title:         { $toString: "$title" },
      date_added: {
        $cond: [
          { $or: [ { $eq: ["$date_added", null] }, { $eq: ["$date_added", ""] } ] },
          null,
          { $toDate: "$date_added" }
        ]
      },
      release_year: {
        $cond: [
          { $or: [ { $eq: ["$release_year", null] }, { $eq: ["$release_year", ""] } ] },
          null,
          { $toInt: "$release_year" }
        ]
      },
      listed_in: {
        $cond: [
          { $or: [ { $eq: ["$listed_in", null] }, { $eq: ["$listed_in", ""] } ] },
          [],
          { $split: ["$listed_in", ", "] }
        ]
      }
    }
  },
  { $out: "netflix" }
], { allowDiskUse: true });
'

sleep 2

docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval '
use ProjectDatabase
db.createCollection("students", {
  validator: {
    $jsonSchema: {
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
'

sleep 2

docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval '
use ProjectDatabase
db.students_raw.aggregate([
  {
    $addFields: {
      "math score":    { $toInt: "$math score" },
      "reading score": { $toInt: "$reading score" },
      "writing score": { $toInt: "$writing score" }
    }
  },
  { $out: "students" }
], { allowDiskUse: true })

print("Imported documents:", db.students.count());
'

sleep 2

docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval '
use ProjectDatabase

db.createCollection("medical_cost", {
  validator: {
    $jsonSchema: {
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
'

sleep 2

docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval '
use ProjectDatabase

db.medical_raw.aggregate([
  {
    $addFields: {
      age:      { $toInt:    "$age" },
      bmi:      { $toDouble: "$bmi" },
      children: { $toInt:    "$children" },
      charges:  { $toDouble: "$charges" }
    }
  },
  { $out: "medical_cost" }
], { allowDiskUse: true })

print("Imported documents:", db.medical_cost.count());
'
sleep 2

echo "Data sent form _raw to correct format"

# 6) Zapnutí shardingu a rozdělení kolekcí

docker exec -it router mongosh \
  -u admin -p password --authenticationDatabase admin \
  --eval '
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

'

echo "Collections sharded"
echo "Cluster initialization complete."