from pymongo import MongoClient
from bson import ObjectId

db = MongoClient("mongodb://localhost:27017")
c = db["Chofer"]["users"]
r1 = c.update_one({"_id": ObjectId("6aaeb1caa102ab6e12ba8eb1")}, {"$set": {"vehicle_type": "basico"}})
r2 = c.update_one({"_id": ObjectId("6aa88681daf3a3cad9a2fd33")}, {"$set": {"vehicle_type": "basico"}})
print("driver_test updated:", r1.modified_count, "| alberto updated:", r2.modified_count)