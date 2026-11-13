# =====================================================================
# Respaldo de la base de Supabase (esquema public: estructura + datos)
#
# Uso:   powershell -ExecutionPolicy Bypass -File supabase\respaldo.ps1
# Requiere:
#   - pg_dump (cliente de PostgreSQL) de una versión IGUAL o MAYOR a la de Supabase.
#     Instalar: winget install PostgreSQL.PostgreSQL.17
#   - SUPABASE_DB_URL como variable de entorno o en .env.local (raíz del proyecto).
#     Se obtiene en Supabase -> Connect -> "Session pooler" (URI con la contraseña de la base).
#
# Guarda en respaldos\AAAA-MM-DD_HHmm.sql y conserva los últimos $Conservar.
# Restaurar:  psql "<SUPABASE_DB_URL>" -f respaldos\ARCHIVO.sql   (ver PLAN_CONTINGENCIAS.md)
# =====================================================================
param([int]$Conservar = 8)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot

# 1. Cadena de conexión
$dbUrl = $env:SUPABASE_DB_URL
$archivoEnv = Join-Path $raiz ".env.local"
if (-not $dbUrl -and (Test-Path $archivoEnv)) {
    foreach ($linea in Get-Content $archivoEnv) {
        if ($linea -match '^\s*SUPABASE_DB_URL\s*=\s*(.+?)\s*$') {
            $dbUrl = $Matches[1].Trim([char[]]@('"', "'"))
        }
    }
}
if (-not $dbUrl) {
    Write-Host "Falta SUPABASE_DB_URL (variable de entorno o .env.local)." -ForegroundColor Red
    exit 1
}

# 2. pg_dump disponible
if (-not (Get-Command pg_dump -ErrorAction SilentlyContinue)) {
    Write-Host "No se encontró pg_dump." -ForegroundColor Red
    Write-Host "Instálalo con:  winget install PostgreSQL.PostgreSQL.17"
    Write-Host "y agrega 'C:\Program Files\PostgreSQL\17\bin' al PATH."
    exit 1
}

# 3. Respaldo
$carpeta = Join-Path $raiz "respaldos"
New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
$destino = Join-Path $carpeta ("{0}.sql" -f (Get-Date -Format "yyyy-MM-dd_HHmm"))

Write-Host "Respaldando en $destino ..."
& pg_dump "--dbname=$dbUrl" --schema=public --no-owner --no-privileges "--file=$destino"
if ($LASTEXITCODE -ne 0) {
    Write-Host "pg_dump falló (código $LASTEXITCODE). Revisa la URL, la contraseña y la versión de pg_dump." -ForegroundColor Red
    if (Test-Path $destino) { Remove-Item $destino -Force }
    exit 1
}

$tamano = [math]::Round((Get-Item $destino).Length / 1KB, 1)
Write-Host "Respaldo listo: $tamano KB" -ForegroundColor Green

# 4. Rotación: conservar solo los más recientes
Get-ChildItem $carpeta -Filter *.sql |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $Conservar |
    ForEach-Object {
        Write-Host "Eliminando respaldo antiguo: $($_.Name)"
        Remove-Item $_.FullName -Force
    }
