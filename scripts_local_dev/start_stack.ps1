# Arranca el stack local: Garnet (6379), tiles (8010), API (18000)
# Uso: powershell -ExecutionPolicy Bypass -File scripts_local_dev\start_stack.ps1
#
# Puertos:
#   6379  Garnet (Redis-compatible)   - indice geo, estados y ofertas de choferes
#   8010  Tiles locales               - /tiles/{z}/{x}/{y}.png
#   18000 API FastAPI                 - panel de escritorio y (via adb reverse) la app
#   En el telefono: 'adb reverse tcp:8000 tcp:18000' para la API y
#   'adb reverse tcp:8010 tcp:8010' para los tiles. Sin el de los tiles el mapa
#   sale en blanco, porque en el telefono no hay nada escuchando en 8010.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$env:PYTHONIOENCODING = 'utf-8'

$ApiPort = 18000
$TilesPort = 8010
$GarnetPort = 6379

function Ensure-Port($port) {
  return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Wait-Port($port, $segundos = 20) {
  $limite = (Get-Date).AddSeconds($segundos)
  while ((Get-Date) -lt $limite) {
    if (Ensure-Port $port) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Test-Url($url) {
  try {
    return (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10).StatusCode
  } catch {
    return 'sin respuesta'
  }
}

# 1) Garnet (Redis-compatible) en 6379
if (Ensure-Port $GarnetPort) {
  Write-Host "Garnet: ya escucha en $GarnetPort"
} else {
  $garnet = 'C:\Users\CARLO\AppData\Local\Temp\opencode\garnet_run\GarnetHost.dll'
  if (Test-Path $garnet) {
    Start-Process dotnet -ArgumentList 'GarnetHost.dll' -WorkingDirectory (Split-Path $garnet) -WindowStyle Hidden
    if (Wait-Port $GarnetPort) {
      Write-Host "Garnet: arrancado en $GarnetPort"
    } else {
      Write-Warning "Garnet no abrio el puerto $GarnetPort; el estado/oferta de choferes fallara."
    }
  } else {
    Write-Warning 'GarnetHost.dll no encontrado; los endpoints de estado/oferta del chofer fallaran.'
  }
}

# 2) Servidor de tiles en 8010
if (Ensure-Port $TilesPort) {
  Write-Host "Tiles: ya escucha en $TilesPort"
} else {
  Start-Process python -ArgumentList 'tiles_server.py' -WorkingDirectory $root -WindowStyle Hidden
  if (Wait-Port $TilesPort) {
    Write-Host "Tiles server: arrancado en $TilesPort"
  } else {
    Write-Warning "El servidor de tiles no abrio el puerto $TilesPort."
  }
}

# 3) Backend FastAPI en 18000
if (Ensure-Port $ApiPort) {
  Write-Host "API: ya escucha en $ApiPort"
} else {
  Start-Process python -ArgumentList '-X','utf8','-m','uvicorn','main_v2:app','--host','127.0.0.1','--port',"$ApiPort" -WorkingDirectory $root -WindowStyle Hidden
  if (Wait-Port $ApiPort 40) {
    Write-Host "Backend: arrancado en $ApiPort"
  } else {
    Write-Warning "El backend no abrio el puerto $ApiPort; revisa el log de uvicorn."
  }
}

Start-Sleep -Seconds 3
Write-Host ''
"API   ${ApiPort}: $(Test-Url "http://127.0.0.1:$ApiPort/docs")"
"Tiles ${TilesPort}: $(Test-Url "http://127.0.0.1:$TilesPort/tiles/16/17771/28444.png")"
"Garnet ${GarnetPort}: $(if (Ensure-Port $GarnetPort) { 'escuchando' } else { 'CAIDO' })"
Write-Host ''

# 4) Reenvios ADB. En el telefono no hay ni la API ni los tiles, asi que sin
#    esto la app no ve el backend y el mapa sale completamente en blanco.
#    Se pierden cada vez que se desconecta el cable, por eso se puesta siempre.
$adb = Get-Command adb -ErrorAction SilentlyContinue
if (-not $adb) {
  Write-Warning 'adb no esta en el PATH; la app en el telefono no vera la API ni los tiles.'
  return
}
$moviles = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $moviles) {
  Write-Warning 'No hay ningun telefono conectado por adb; el mapa de la app saldra vacio.'
  return
}
foreach ($m in $moviles) {
  & adb -s $m reverse tcp:8000 tcp:$ApiPort | Out-Null
  & adb -s $m reverse tcp:$TilesPort tcp:$TilesPort | Out-Null
  $listados = (& adb -s $m reverse --list) -join ' | '
  Write-Host "adb reverse en $m -> $listados"
}
Write-Host "Listo: API en localhost:8000 y tiles en localhost:$TilesPort dentro del telefono."
