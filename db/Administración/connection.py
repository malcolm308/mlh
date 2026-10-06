from pymongo import MongoClient

client = MongoClient("mongodb://localhost:27017")
admin_db = client["Administración"]