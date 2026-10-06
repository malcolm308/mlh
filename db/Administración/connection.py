import os

from pymongo import MongoClient

client = MongoClient(os.getenv("MONGODB_URI", "mongodb://localhost:27017"))
admin_db = client["Administración"]