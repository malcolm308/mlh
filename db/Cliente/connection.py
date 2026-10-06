from pymongo import MongoClient

client = MongoClient("mongodb://localhost:27017")
cliente_db = client["Cliente"]