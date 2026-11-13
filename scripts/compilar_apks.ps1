# Compila las apps de cliente y chofer (64 + 32 bits) con la clave de MapTiler.
#
# Sin `--dart-define=MAPTILER_API_KEY` la app cae al estilo propio de Martin
# (`https://mlh-tdyg.onrender.com/style/taxi`) y el mapa deja de ser el de
# MapTiler. Como la clave se compila dentro de `libapp.so`, un parche tambien
# la arrastra: si se publica un build sin clave, los telefonos que reciban ese
# parche pierden el estilo de MapTiler.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File scripts\compilar_apks.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\compilar_apks.ps1 -MaptilerKey OTRA_CLAVE
#
# Despues hay que publicar los manifiestos con scripts\publicar_ota.py y
# generar los parches (ver README).
param(
    [string]$MaptilerKey = 'ZsGcg7EJ3Ml7wgFfXwAt'
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$apps = @(
    @{ dir = 'taxi_client'; nombre = 'app_cliente' },
    @{ dir = 'taxi_driver'; nombre = 'app_chofer' }
)

foreach ($app in $apps) {
    $ruta = Join-Path $raiz "frontend\$($app.dir)"
    Push-Location $ruta
    try {
        Write-Host "[build] $($app.dir) con MapTiler..." -ForegroundColor Cyan
        flutter build apk --release --split-per-abi --no-pub `
            --dart-define=MAPTILER_API_KEY=$MaptilerKey
        if ($LASTEXITCODE -ne 0) { throw "Fallo el build de $($app.dir)" }

        $salida = 'build\app\outputs\flutter-apk'
        Copy-Item "$salida\app-arm64-v8a-release.apk" `
            (Join-Path $raiz "static\$($app.nombre)_64bits.apk") -Force
        Copy-Item "$salida\app-armeabi-v7a-release.apk" `
            (Join-Path $raiz "static\$($app.nombre)_32bits.apk") -Force
        Write-Host "[build] $($app.nombre) 64/32 bits copiados a static\" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}
