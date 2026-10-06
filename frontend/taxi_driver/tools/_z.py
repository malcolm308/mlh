import sqlite3
c = sqlite3.connect(r"E:\Taxi_Rapid\tiles\tilesets\cuba.mbtiles")
print("  zmin,zmax:", c.execute("select min(zoom_level),max(zoom_level) from tiles").fetchone())
for z, n, avg in c.execute("select zoom_level,count(*),avg(length(tile_data)) from tiles group by 1 order by 1"):
    print("  z%-2d %5d tiles  medio %6.1f KB" % (z, n, avg/1024))
