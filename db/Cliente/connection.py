import os

from pymongo import MongoClient

client = MongoClient(os.getenv("MONGODB_URI", "mongodb://localhost:27017"))
cliente_db = client["Cliente"]