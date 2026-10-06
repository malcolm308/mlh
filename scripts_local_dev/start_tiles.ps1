# Arranca el servidor de vector tiles (Martin) en el puerto 8010.
#
#   powershell -ExecutionPolicy Bypass -File scripts_local_dev\start_tiles.ps1
#
# Sustituye al antiguo tiles_server.py, que servia PNG raster generados con
# OSM. Martin sirve MBTiles VECTORIALES (PBF), que es lo que necesita
# maplibre_gl.
#
# Por que Martin y no tileserver-gl: tileserver-gl solo se distribuye por npm y
# por Docker, y aqui no hay Node.js ni Docker. Martin es un binario unico de
# Rust que publica tambien Windows.
#
# Por que Martin y no mbtileserver: mbtileserver no publica binario de Windows
# desde 2021.
#
# Comprobaciones:
#   http://127.0.0.1:8010/catalog
#   http://127.0.0.1:8010/style/taxi
#   http://127.0.0.1:8010/cuba/14/4443/7110.pbf   (PBF real, ~213 KB)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$Martin = Join-Path $root 'tileserver\martin.exe'
$Port = 8010

function Test-Port($p) {
  return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

if (Test-Path $Martin) {
  Write-Host "Martin encontrado en $Martin"
} else {
  Write-Error "No existe $Martin. Descargalo de https://github.com/maplibre/martin/releases"
}

# Si el puerto esta ocupado, ver quien es antes de matarlo: puede ser el
# tiles_server.py antiguo, que hay que parar para liberar el puerto.
if (Test-Port $Port) {
  $quien = Get-NetTCPConnection -LocalPort $Port -State Listen |
    ForEach-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
  Write-Host "El puerto $Port ya lo ocupa: $($quien -join ', ')"

  if ($quien -contains 'python') {
    Write-Host '  Es el tiles_server.py antiguo (PNG). Se detiene: el mapa ahora es vectorial.'
    Get-NetTCPConnection -LocalPort $Port -State Listen |
      ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
  } else {
    Write-Error "  Ya hay otro servidor en $Port. Para y vuelve a lanzar."
  }
}

# Argumentos:
#   <carpeta de tilesets>  origen de los MBTiles
#   --style <carpeta>       estilos que se publican en /style/<nombre>
#   --font <carpeta>        fuentes TTF para los nombres de calle
#   --listen-addresses      8010, el puerto que ya usan la app y el adb reverse
Start-Process $Martin -ArgumentList @(
  (Join-Path $root 'tiles\tilesets'),
  '--style', (Join-Path $root 'tileserver\styles'),
  '--font', (Join-Path $root 'tileserver\fonts'),
  '--listen-addresses', "0.0.0.0:$Port"
) -WindowStyle Hidden

# Esperar a que abra el puerto
$limite = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $limite) {
  if (Test-Port $Port) { break }
  Start-Sleep -Milliseconds 500
}

if (Test-Port $Port) {
  Write-Host "Martin escuchando en $Port"
} else {
  Write-Error "Martin no abrio el puerto $Port."
}

Start-Sleep -Seconds 2
foreach ($u in @("catalog", "style/taxi")) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:$Port/$u" -UseBasicParsing -TimeoutSec 15
    Write-Host "  /$u -> HTTP $($r.StatusCode)"
  } catch {
    Write-Warning "  /$u -> $($_.Exception.Message)"
  }
}

# El reenvio ADB se pierde en cuanto se desconecta el cable, asi que se pone
# siempre. Sin el de los tiles el mapa sale en blanco.
$adb = Get-Command adb -ErrorAction SilentlyContinue
if ($adb) {
  $moviles = @(& adb devices | Select-Object -Skip 1 |
    Where-Object { $_ -match '\sdevice$' } |
    ForEach-Object { ($_ -split '\s+')[0] })
  foreach ($m in $moviles) {
    & adb -s $m reverse "tcp:$Port" "tcp:$Port" | Out-Null
    Write-Host "  adb reverse tcp:$Port en $m"
  }
}

Write-Host ''
Write-Host "Estilo para la app: http://127.0.0.1:$Port/style/taxi"
