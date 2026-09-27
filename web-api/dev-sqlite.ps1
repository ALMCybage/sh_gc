# Local dev without MySQL, Redis or GCP.
#
# Points every tenant at its own SQLite file, keeps cache/sessions on disk, logs
# Pub/Sub envelopes instead of publishing, and stores request statuses in the
# Laravel cache. Enough to run the SPA against a real API end to end.
#
#   . .\dev-sqlite.ps1            # load the env into this shell
#   php artisan tenants:migrate --seed --create-schema=0
#   php artisan serve --port=8080
#
# Then browse to http://acme.localhost:5173 (Vite proxies /api to :8080).

$root = (Resolve-Path "$PSScriptRoot").Path.Replace('\', '/')
$dbDir = "$root/database/sqlite"

New-Item -ItemType Directory -Force -Path $dbDir | Out-Null

foreach ($tenant in @('acme', 'whiteknight', 'frdm')) {
    $file = "$dbDir/$tenant.sqlite"
    if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
}

$env:DB_CONNECTION = 'sqlite'
$env:TENANCY_TEMPLATE_CONNECTION = 'sqlite'
$env:DB_DATABASE = "$dbDir/acme.sqlite"

# The tenant "database" is a file path here instead of a MySQL schema name. Same
# TenantManager code path: clone the template connection, swap the database.
$env:TENANTS_JSON = @"
{
  "acme":        {"name": "Acme Corp",    "database": "$dbDir/acme.sqlite",        "domain": "acme.sequifi.com"},
  "whiteknight": {"name": "White Knight", "database": "$dbDir/whiteknight.sqlite", "domain": "whiteknight.sequifi.com"},
  "frdm":        {"name": "FRDM",         "database": "$dbDir/frdm.sqlite",        "domain": "frdm.sequifi.com"}
}
"@

$env:CACHE_DRIVER = 'file'
$env:SESSION_DRIVER = 'file'
$env:PUBSUB_DRIVER = 'log'
$env:FIRESTORE_DRIVER = 'cache'
$env:PUBSUB_EMULATOR_HOST = ''
$env:FIRESTORE_EMULATOR_HOST = ''
$env:TENANCY_BASE_DOMAINS = 'sequifi.com,localhost'
$env:TENANCY_TRUST_HEADER = 'true'
$env:SESSION_DOMAIN = ''
$env:SANCTUM_STATEFUL_DOMAINS = '*.localhost,*.localhost:5173,localhost:5173,localhost:8080,127.0.0.1:8080'

Write-Host "[dev-sqlite] tenants -> $dbDir" -ForegroundColor Green
Write-Host "[dev-sqlite] pubsub=log firestore=cache cache=file session=file" -ForegroundColor Green
