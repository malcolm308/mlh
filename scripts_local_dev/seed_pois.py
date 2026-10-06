"""
Siembra la coleccion `pois` con los principales hoteles, hostales, bares y
centros recreativos de La Habana. Idempotente: no duplica nombres.

Ejecutar desde E:\Taxi_Rapid:
    python -X utf8 scripts_local_dev\seed_pois.py
"""
import sys

sys.path.insert(0, r"E:\Taxi_Rapid")

from pymongo import MongoClient

_db = MongoClient("mongodb://localhost:27017")["Administraci\u00f3n"]
_pois = _db["pois"]

POIS = [
    # ---------------- HOTELES ----------------
    ("hotel", "Hotel Nacional de Cuba", 23.1275, -82.3828, "Calle 21 e/ O y N, Vedado"),
    ("hotel", "Hotel Habana Libre", 23.1357, -82.3821, "L y 23, Vedado"),
    ("hotel", "Hotel Melia Cohiba", 23.1417, -82.3826, "Paseo y 13, Vedado"),
    ("hotel", "Hotel Riviera", 23.1371, -82.3926, "Paseo y Malecon, Vedado"),
    ("hotel", "Hotel Capri", 23.1384, -82.3779, "N y 21, Vedado"),
    ("hotel", "Hotel Presidente", 23.1388, -82.3944, "Calzada y G, Vedado"),
    ("hotel", "Hotel Victoria", 23.1325, -82.4003, "19 y M, Vedado"),
    ("hotel", "Hotel Colina", 23.1341, -82.3974, "L y 27, Vedado"),
    ("hotel", "Hotel Vedado", 23.1364, -82.3972, "Calle O y 25, Vedado"),
    ("hotel", "Gran Hotel Manzana Kinsley Kempinski", 23.1360, -82.3595, "San Rafael y Zulueta"),
    ("hotel", "Iberostar Parque Central", 23.1370, -82.3582, "Neptuno y Zulueta"),
    ("hotel", "Hotel Inglaterra", 23.1357, -82.3575, "Paseo del Prado 416"),
    ("hotel", "Hotel Sevilla", 23.1368, -82.3577, "Trocadero 55"),
    ("hotel", "Hotel Telegrafo", 23.1340, -82.3565, "Prado y Neptuno"),
    ("hotel", "Hotel Deauville", 23.1351, -82.3610, "Galiano y Malecon"),
    ("hotel", "Hotel Packard", 23.1365, -82.3604, "Prado y San Miguel"),
    ("hotel", "Hotel Saratoga", 23.1326, -82.3549, "Prado 603"),
    ("hotel", "Hotel Florida", 23.1336, -82.3552, "Obispo 11"),
    ("hotel", "Hotel Ambos Mundos", 23.1380, -82.3506, "Obispo 153"),
    ("hotel", "Hotel Santa Isabel", 23.1396, -82.3515, "Plaza de Armas"),
    ("hotel", "Hotel Palacio O'Farrill", 23.1370, -82.3520, "Cuba 101"),
    ("hotel", "Hotel Raquel", 23.1363, -82.3531, "Belascoain 106"),
    ("hotel", "Hotel Los Frailes", 23.1372, -82.3512, "Teniente Rey 8"),
    ("hotel", "Hotel Melia Habana", 23.1043, -82.4110, "5a Ave y 3a, Miramar"),
    ("hotel", "Hotel Copacabana", 23.1200, -82.4170, "1ra y 44, Miramar"),
    ("hotel", "Hotel Comodoro", 23.0961, -82.4485, "Calle C y 3ra, La Concha"),
    ("hotel", "Hotel Montehabana", 23.1281, -82.4065, "Calle 6, Miramar"),
    ("hotel", "Hotel Neptuno-Tribuna", 23.1167, -82.4530, "Calle 29 y Ave 3ra"),
    ("hotel", "Hotel St. John's", 23.1300, -82.4060, "Av 47 y 3ra, Miramar"),
    # ---------------- HOSTALES / CASAS ----------
    ("hostal", "Hostal San Cristobal", 23.1375, -82.3520, "San Rafael 1111"),
    ("hostal", "Hostal Casa Bella", 23.1392, -82.3508, "Empedrado 354"),
    ("hostal", "Hostal Dona Mela", 23.1399, -82.3530, "Tacon 152"),
    ("hostal", "Hostal Casa 1932", 23.1401, -82.3530, "Villegas 210"),
    ("hostal", "Hostal Barcelona", 23.1348, -82.3556, "Lealtad 255"),
    ("hostal", "Hostal Boulevard Habana", 23.1376, -82.3561, "San Rafael 506 e/ Oquendo y Campanario"),
    ("hostal", "Hostal Los Catedrales", 23.1382, -82.3501, "Aguacate 356"),
    ("hostal", "Hostal La Herencia", 23.1378, -82.3515, "Habana 425"),
    ("hostal", "Hostal Cuba", 23.1402, -82.3495, "Cuba 215"),
    ("hostal", "Hostal Rincon Criollo", 23.1390, -82.3880, "Calle 12 e/ 23 y 25, Vedado"),
    ("hostal", "Hostal Santa Maria", 23.1385, -82.3805, "Calle 17 y E, Vedado"),
    ("hostal", "Hostal Secreto de Willy", 23.1405, -82.3790, "Calle 23 y G, Vedado"),
    ("hostal", "Hostal El Padrino", 23.1290, -82.3875, "Calle 27 y 4, Vedado"),
    ("hostal", "Hostal Casa Vitoria", 23.1320, -82.3700, "Calle Zulueta y Malecon, Centro Habana"),
    ("hostal", "Hostal La Ortopedia", 23.1330, -82.3810, "Calle 11 y 14, Vedado"),
    # ---------------- BARES ----------------
    ("bar", "La Bodeguita del Medio", 23.1382, -82.3497, "Empedrado 207"),
    ("bar", "El Floridita", 23.1370, -82.3570, "Obispo y Monserrate"),
    ("bar", "Sloppy Joe's", 23.1352, -82.3576, "Corrales 104"),
    ("bar", "O'Reilly 304", 23.1386, -82.3520, "O'Reilly 304"),
    ("bar", "Bar Doce", 23.1395, -82.3510, "Monserrate y O'Reilly"),
    ("bar", "Cafe El Escorial", 23.1384, -82.3512, "Mercaderes 317"),
    ("bar", "Nao Bar Paladar", 23.1393, -82.3500, "Oficios y Amargura"),
    ("bar", "La Fruteria", 23.1386, -82.3545, "Luz 451"),
    ("bar", "El Cocinero", 23.1398, -82.3850, "Calle 26 y 41, Vedado"),
    ("bar", "Fabrica de Arte Cubano (bar)", 23.1269, -82.4066, "Calle 26 y 11, Nuevo Vedado"),
    ("bar", "Casa de la Musica Miramar", 23.1158, -82.4242, "Calle 20 y 35, Miramar"),
    ("bar", "Casa de la Musica Galiano", 23.1301, -82.3661, "Galiano y Neptuno, Centro Habana"),
    ("bar", "La Zorra y El Cuervo", 23.1320, -82.3925, "Calle 23 y O, Vedado"),
    ("bar", "Cafe Cantante Mi Habana", 23.1396, -82.3830, "Calle Paseo y 17, Vedado"),
    ("bar", "La Fresa y El Cafe", 23.1403, -82.3800, "Calle 12 y 23, Vedado"),
    ("bar", "Bar Salon Rojo (Hotel Capri)", 23.1384, -82.3779, "Calle 21 y N, Vedado"),
    # ---------------- CENTROS RECREATIVOS ------
    ("centro_recreativo", "Cabaret Tropicana", 23.1185, -82.4093, "Calle 72 y 45, Marianao"),
    ("centro_recreativo", "Gran Teatro de La Habana Alicia Alonso", 23.1365, -82.3588, "Prado y San Rafael"),
    ("centro_recreativo", "Teatro Nacional de Cuba", 23.1161, -82.3900, "Plaza de la Revolucion, Vedado"),
    ("centro_recreativo", "Cine Yara", 23.1382, -82.3900, "Calle 23 y L, Vedado"),
    ("centro_recreativo", "Sala Polivalente Kid Chocolate", 23.1296, -82.3889, "Calle 23 y 6, Vedado"),
    ("centro_recreativo", "Pabellon Cuba", 23.1334, -82.3940, "Calle 23 y N, Vedado"),
    ("centro_recreativo", "Coppelia (La Piragua)", 23.1391, -82.3880, "Calle 23 y L, Vedado"),
    ("centro_recreativo", "Jardines de la Tropical", 23.1002, -82.3820, "Calle 41, Cerro"),
    ("centro_recreativo", "Museo de la Revolucion", 23.1414, -82.3570, "Refugio 1"),
    ("centro_recreativo", "Museo Nacional de Bellas Artes", 23.1395, -82.3551, "Trocadero y Zulueta"),
    ("centro_recreativo", "Museo del Ron", 23.1405, -82.3494, "Avenida del Puerto 262"),
    ("centro_recreativo", "Parque Morro-Cabana", 23.1498, -82.3500, "Alto del Cerro de la Cabana"),
    ("centro_recreativo", "Castillo de la Real Fuerza", 23.1410, -82.3508, "Plaza de Armas"),
    ("centro_recreativo", "Acuario Nacional", 23.1171, -82.4156, "Av 3ra y Calle 62, Miramar"),
    ("centro_recreativo", "Anfiteatro del Malecon", 23.1447, -82.3574, "Malecon y Prado"),
]


def main():
    ok = dup = 0
    for cat, nombre, lat, lng, direccion in POIS:
        if _pois.find_one({"nombre": nombre, "categoria": cat}):
            dup += 1
            continue
        _pois.insert_one(
            {"nombre": nombre, "categoria": cat, "lat": lat, "lng": lng, "direccion": direccion}
        )
        ok += 1
    _pois.create_index("categoria")
    _pois.create_index([("nombre", 1), ("categoria", 1)], unique=True)
    print(f"Insertados: {ok} | Ya existian: {dup} | Total en DB: {_pois.count_documents({})}")


if __name__ == "__main__":
    main()