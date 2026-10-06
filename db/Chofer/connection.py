from pymongo import MongoClient

client = MongoClient("mongodb://localhost:27017")
chofer_db = client["Chofer"]