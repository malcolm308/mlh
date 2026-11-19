import os, psycopg2

url = os.environ.get("SUPABASE_DB_URL", "")
print("Proyecto (ref) al que apunta tu URL:", url.split("@")[0].split("postgres.")[-1] if url else "(VACIA)")
print("Servidor:", url.split("@")[-1] if url else "(VACIA)")

c = psycopg2.connect(url)
cur = c.cursor()
cur.execute("select current_database(), current_user, inet_server_addr()")
print("Base de datos / usuario / IP:", cur.fetchone())

cur.execute("select to_regclass('public.zones'), to_regclass('public.outbox')")
print("Tablas que el script SI ve:", cur.fetchone())

cur.execute("select version from schema_migrations order by version")
print("Migraciones registradas en ESTA base:", cur.fetchall())