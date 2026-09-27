# Windows equivalent of the Makefile targets.
#
#   .\dev.ps1 up        build and start the whole local stack
#   .\dev.ps1 test      run every test suite
#   .\dev.ps1 smoke     exercise the running stack end to end
#   .\dev.ps1 help      list everything
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = 'help',

    [string]$Tenant = 'acme',
    [int]$Workers = 3
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$base = "http://$Tenant.localhost:8080"

function Invoke-Step($description, [scriptblock]$action) {
    Write-Host "==> $description" -ForegroundColor Cyan
    & $action
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$description failed with exit code $LASTEXITCODE"
    }
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker is not on PATH. Install Docker Desktop, or use the no-Docker path: web-api\dev-sqlite.ps1'
    }
}

switch ($Target) {
    'help' {
        Write-Host ''
        Write-Host '  Local stack' -ForegroundColor Yellow
        Write-Host '    up                Build and start everything, then migrate and seed'
        Write-Host '    down              Stop the stack, keep data'
        Write-Host '    clean             Stop the stack and delete all data'
        Write-Host '    migrate           Create, migrate and seed every tenant schema'
        Write-Host '    logs              Tail application logs'
        Write-Host '    ps                Service status'
        Write-Host '    scale-workers     Scale the worker pool (-Workers 3)'
        Write-Host '    rebuild-frontend  Rebuild the SPA and restart nginx'
        Write-Host ''
        Write-Host '  Verification' -ForegroundColor Yellow
        Write-Host '    test              Every test suite (Go + PHP + frontend build)'
        Write-Host '    test-go           Go build, vet and unit tests'
        Write-Host '    test-php          PHP feature tests'
        Write-Host '    test-frontend     Typecheck and production-build the SPA'
        Write-Host '    lint              Formatting, static checks, YAML validation'
        Write-Host '    smoke             Exercise the running stack end to end'
        Write-Host ''
        Write-Host '  No Docker?' -ForegroundColor Yellow
        Write-Host '    cd web-api; . .\dev-sqlite.ps1; php artisan tenants:migrate --seed --create-schema=0'
        Write-Host '    php artisan serve --port=8099    (then run the SPA with: cd frontend; npm run dev)'
        Write-Host ''
    }

    'up' {
        Assert-Docker
        Invoke-Step 'Building and starting the stack' { docker compose up -d --build }
        Invoke-Step 'Migrating and seeding tenants' { docker compose run --rm migrate }
        Write-Host ''
        Write-Host "  Ready: $base" -ForegroundColor Green
        Write-Host "  Sign in as admin@$Tenant.test / password" -ForegroundColor Green
        Write-Host '  Other tenants: whiteknight.localhost:8080, frdm.localhost:8080'
        Write-Host "  Roles: owner@ / admin@ / operator@ / viewer@$Tenant.test"
        Write-Host ''
    }

    'down' { Assert-Docker; docker compose down }
    'clean' { Assert-Docker; docker compose down -v --remove-orphans }
    'migrate' { Assert-Docker; docker compose run --rm migrate }
    'logs' { Assert-Docker; docker compose logs -f web-api worker nginx }
    'ps' { Assert-Docker; docker compose ps }

    'scale-workers' {
        Assert-Docker
        Invoke-Step "Scaling the worker pool to $Workers" { docker compose up -d --scale worker=$Workers }
    }

    'rebuild-frontend' {
        Assert-Docker
        Invoke-Step 'Rebuilding the SPA' { docker compose run --rm frontend-build }
        Invoke-Step 'Restarting nginx' { docker compose restart nginx }
    }

    'test' {
        & $PSCommandPath 'test-go'
        & $PSCommandPath 'test-php'
        & $PSCommandPath 'test-frontend'
    }

    'test-go' {
        Push-Location (Join-Path $root 'worker-go')
        try {
            Invoke-Step 'go build' { go build ./... }
            Invoke-Step 'go vet' { go vet ./... }
            Invoke-Step 'go test' { go test ./... -count=1 }
        } finally { Pop-Location }
    }

    'test-php' {
        Push-Location (Join-Path $root 'web-api')
        try {
            Invoke-Step 'phpunit' { .\vendor\bin\phpunit }
        } finally { Pop-Location }
    }

    'test-frontend' {
        Push-Location (Join-Path $root 'frontend')
        try {
            if (-not (Test-Path 'node_modules')) { Invoke-Step 'npm ci' { npm ci } }
            Invoke-Step 'typecheck + build' { npm run build }
        } finally { Pop-Location }
    }

    'lint' {
        Push-Location (Join-Path $root 'worker-go')
        try {
            $unformatted = gofmt -l .
            if ($unformatted) { throw "gofmt found unformatted files:`n$unformatted" }
            Invoke-Step 'go vet' { go vet ./... }
        } finally { Pop-Location }

        Invoke-Step 'YAML validation' { python (Join-Path $root 'scripts\validate-yaml.py') }
    }

    'smoke' {
        Push-Location (Join-Path $root 'web-api')
        try {
            Invoke-Step 'Smoke test' { .\smoke-auth.ps1 -Base $base -TenantHost "$Tenant.localhost:8080" -Origin $base }
        } finally { Pop-Location }
    }

    default { throw "Unknown target '$Target'. Run .\dev.ps1 help" }
}
