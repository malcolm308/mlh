print('=== Creando base de datos taxi_clientes ===');
db = db.getSiblingDB('taxi_clientes');

db.createCollection('usuarios');

db.usuarios.insertMany([
  {
    nombre: 'Carlos Martinez',
    email: 'carlos@email.com',
    telefono: '+53 5555-1234',
    password: 'hashed_password_1',
    fecha_registro: new Date(),
    activo: true
  },
  {
    nombre: 'Ana Rodriguez',
    email: 'ana@email.com',
    telefono: '+53 5555-5678',
    password: 'hashed_password_2',
    fecha_registro: new Date(),
    activo: true
  },
  {
    nombre: 'Luis Gomez',
    email: 'luis@email.com',
    telefono: '+53 5555-9012',
    password: 'hashed_password_3',
    fecha_registro: new Date(),
    activo: true
  }
]);

print('Clientes creados: ' + db.usuarios.countDocuments());

print('=== Creando base de datos taxi_conductores ===');
db = db.getSiblingDB('taxi_conductores');

db.createCollection('usuarios');

db.usuarios.insertMany([
  {
    nombre: 'Roberto Perez',
    email: 'roberto@email.com',
    telefono: '+53 5555-1111',
    password: 'hashed_password_4',
    licencia: 'LIC-001-HAB',
    vehiculo: 'Hyundai Accent 2020',
    placa: 'HH-123-45',
    fecha_registro: new Date(),
    activo: true,
    calificacion: 4.8,
    ubicacion_actual: { lat: 23.1352, lng: -82.3589 }
  },
  {
    nombre: 'Maria Fernandez',
    email: 'maria@email.com',
    telefono: '+53 5555-2222',
    password: 'hashed_password_5',
    licencia: 'LIC-002-HAB',
    vehiculo: 'Kia Rio 2019',
    placa: 'HH-678-90',
    fecha_registro: new Date(),
    activo: true,
    calificacion: 4.5,
    ubicacion_actual: { lat: 23.1420, lng: -82.3650 }
  },
  {
    nombre: 'Jorge Diaz',
    email: 'jorge@email.com',
    telefono: '+53 5555-3333',
    password: 'hashed_password_6',
    licencia: 'LIC-003-HAB',
    vehiculo: 'Toyota Yaris 2021',
    placa: 'HH-111-22',
    fecha_registro: new Date(),
    activo: true,
    calificacion: 4.9,
    ubicacion_actual: { lat: 23.1280, lng: -82.3510 }
  }
]);

print('Conductores creados: ' + db.usuarios.countDocuments());

print('=== Bases de datos creadas exitosamente ===');
print('');
print('Listando bases de datos:');
db.getMongo().getDBs().databases.forEach(function(d) {
  if (d.name.includes('taxi')) print('  - ' + d.name);
});

print('');
print('Colecciones en taxi_clientes:');
db.getSiblingDB('taxi_clientes').getCollectionNames().forEach(function(c) {
  print('  - ' + c + ' (' + db.getSiblingDB('taxi_clientes').getCollection(c).countDocuments() + ' documentos)');
});

print('');
print('Colecciones en taxi_conductores:');
db.getSiblingDB('taxi_conductores').getCollectionNames().forEach(function(c) {
  print('  - ' + c + ' (' + db.getSiblingDB('taxi_conductores').getCollection(c).countDocuments() + ' documentos)');
});
