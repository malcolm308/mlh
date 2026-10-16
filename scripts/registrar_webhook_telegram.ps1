<#
.SYNOPSIS
    Registra y verifica el webhook del bot de Telegram.

.DESCRIPTION
    Habla con la API de Telegram usando las variables de entorno, sin escribir el
    token en disco ni en el historial de PowerShell:

        TELEGRAM_BOT_TOKEN        Token que entrega @BotFather
        TELEGRAM_WEBHOOK_SECRET   Secreto de la cabecera X-Telegram-Bot-Api-Secret-Token
        TELEGRAM_WEBHOOK_URL      URL publica del backend (por defecto la de Render)

    El secreto se pasa por `-SecretToken` en la llamada a `setWebhook`, que es
    como Telegram valida las peticiones posteriores. El mismo valor debe estar en
    `TELEGRAM_WEBHOOK_SECRET` en el servidor: ahi es donde el bot lo compara.

.PARAMETER PublicUrl
    URL base del backend, sin la ruta del webhook.

.PARAMETER SecretToken
    Secreto de la cabecera. Si se omite se usa TELEGRAM_WEBHOOK_SECRET.

.PARAMETER Remove
    Borra el webhook en vez de registrarlo (deja el bot en modo getUpdates).

.EXAMPLE
    .\registrar_webhook_telegram.ps1
    .\registrar_webhook_telegram.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$PublicUrl = $(if ($env:TELEGRAM_WEBHOOK_URL) { $env:TELEGRAM_WEBHOOK_URL } else { "https://rapitaxi-api-fws6.onrender.com" }),
    [string]$SecretToken = $(if ($env:TELEGRAM_WEBHOOK_SECRET) { $env:TELEGRAM_WEBHOOK_SECRET } else { "" }),
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

function Invoke-Telegram {
    param([string]$Metodo, [hashtable]$Parametros = @{})

    $uri = "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/$Metodo"
    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Body $Parametros -TimeoutSec 30
    }
    catch {
        throw "Fallo la llamada a $Metodo : $($_.Exception.Message)"
    }
}

if (-not $env:TELEGRAM_BOT_TOKEN) {
    Write-Error "Falta TELEGRAM_BOT_TOKEN en el entorno. Configurala antes de seguir."
    exit 1
}

if (-not $Remove -and -not $SecretToken) {
    Write-Error "Falta el secreto del webhook. Usa -SecretToken o define TELEGRAM_WEBHOOK_SECRET."
    exit 1
}

Write-Host "1. Comprobando el token con getMe..."
$yo = Invoke-Telegram -Metodo "getMe"
if (-not $yo.ok) { Write-Error "El token no es valido."; exit 1 }
Write-Host "   Bot: @$($yo.result.username) ($($yo.result.first_name))"

if ($Remove) {
    Write-Host "2. Borrando el webhook..."
    $borrado = Invoke-Telegram -Metodo "deleteWebhook" -Parametros @{ drop_pending_updates = "true" }
    Write-Host "   $($borrado.description)"
    exit 0
}

# El token va en la ruta porque el endpoint es /webhook/{token}.
$urlWebhook = "$($PublicUrl.TrimEnd('/'))/webhook/$($env:TELEGRAM_BOT_TOKEN)"

Write-Host "2. Registrando el webhook en:"
Write-Host "   $urlWebhook"

$registrado = Invoke-Telegram -Metodo "setWebhook" -Parametros @{
    url                  = $urlWebhook
    secret_token         = $SecretToken
    allowed_updates      = '["message","callback_query"]'
    drop_pending_updates = "true"
    max_connections      = "40"
}

if (-not $registrado.ok) {
    Write-Error "Telegram no acepto el webhook: $($registrado.description)"
    exit 1
}
Write-Host "   $($registrado.description)"

Write-Host "3. Verificando con getWebhookInfo..."
$info = Invoke-Telegram -Metodo "getWebhookInfo"
$resultado = $info.result
Write-Host "   URL:            $($resultado.url)"
Write-Host "   Errores:        $($resultado.last_error_message -replace "`n", ' ')"
Write-Host "   Actualizaciones pendientes: $($resultado.pending_update_count)"
Write-Host "   Conexiones maximas: $($resultado.max_connections)"

# `getWebhookInfo` NO devuelve un campo `status`: lo unico que dice si el webhook
# funciona es si hay `last_error_message` (Telegram no pudo entregar una
# actualizacion) y si se acumulo`pending_update_count` (nada llego nunca).
if ($resultado.url -ne $urlWebhook) {
    Write-Error "La URL registrada no es la esperada. Se registro otra cosa."
    exit 1
}

if ($resultado.last_error_message) {
    Write-Error "Telegram no ha podido entregar una actualizacion: $($resultado.last_error_message)"
    Write-Error "Si el backend no esta desplegado o el secreto no coincide, eso es lo que vera."
    exit 1
}

if ($resultado.pending_update_count -gt 0) {
    Write-Warning "Hay $($resultado.pending_update_count) actualizacion(es) sin entregar. Si el bot no responde, mira el log del servidor: lo mas probable es que el secreto no coincida."
}

Write-Host ""
Write-Host "4. Comprobando que el backend responde en /telegram/status..."
try {
    $estado = Invoke-RestMethod -Method Get -Uri "$($PublicUrl.TrimEnd('/'))/telegram/status" -TimeoutSec 30
    Write-Host "   webhook_configurado: $($estado.webhook_configurado)"
    Write-Host "   administradores:      $($estado.administradores)"
    Write-Host "   tope por pasada:      $($estado.tope_por_pasada_automatica)"

    if (-not $estado.webhook_configurado) {
        Write-Warning "El backend responde, pero no ve TELEGRAM_BOT_TOKEN o TELEGRAM_WEBHOOK_SECRET. Revisalos en Render y reinicia el servicio."
        exit 1
    }
}
catch {
    Write-Warning "El backend no respondio en /telegram/status: $($_.Exception.Message)"
    Write-Warning "Si el webhook quedo en 'ok' pero esto falla, normalmente es que la base todavia no ha despertado."
}

Write-Host ""
Write-Host "Webhook listo. Abre el bot en Telegram y manda /start."