# End-to-end smoke test of the SPA session-auth flow, exactly as the browser does
# it: csrf-cookie -> login -> authenticated reads -> async submit -> logout.
#
#   . .\dev-sqlite.ps1
#   php artisan serve --port=8099     # in another shell
#   .\smoke-auth.ps1 -Base http://127.0.0.1:8099

param(
    [string]$Base = 'http://127.0.0.1:8099',
    [string]$TenantHost = 'acme.localhost',
    [string]$Origin = 'http://acme.localhost:5173'
)

$ErrorActionPreference = 'Stop'

$jar = Join-Path $env:TEMP 'sequifi-cookies.txt'
$bodyFile = Join-Path $env:TEMP 'sequifi-body.json'
Remove-Item $jar -ErrorAction SilentlyContinue

$common = @(
    '-s', '-b', $jar, '-c', $jar,
    '-H', "Host: $TenantHost",
    '-H', "Origin: $Origin",
    '-H', "Referer: $Origin/"
)

$failures = 0

function Show($label, $body, $code, $expected) {
    $ok = ([int]$code -eq $expected)
    if (-not $ok) { $script:failures++ }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-46} {2} (want {3})" -f $mark, $label, $code, $expected) -ForegroundColor $colour
    if ($body) {
        $trimmed = if ($body.Length -gt 220) { $body.Substring(0, 220) + '...' } else { $body }
        Write-Host "        $trimmed" -ForegroundColor DarkGray
    }
}

function Call($label, $expected, [string[]]$extra) {
    $raw = (& curl.exe @common @extra -w "`n%{http_code}") -join "`n"
    $lines = $raw -split "`n"
    $code = $lines[-1].Trim()
    $body = ($lines[0..($lines.Length - 2)] -join '').Trim()
    Show $label $body $code $expected
    return $body
}

# PowerShell mangles double quotes inside native-command arguments, so JSON goes
# through a file rather than -d.
function Post($label, $expected, $path, $json, $idempotencyKey) {
    # UTF8 *without* a BOM. Set-Content -Encoding utf8 on PowerShell 5.1 writes a
    # BOM, which makes the payload invalid JSON and every field look absent.
    [System.IO.File]::WriteAllText($bodyFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $extra = @(
        '-X', 'POST', "$Base$path",
        '-H', 'Content-Type: application/json',
        '-H', "X-XSRF-TOKEN: $(XsrfToken)"
    )

    # The write endpoints require an Idempotency-Key so a retry cannot queue the
    # work twice. Omitted deliberately in the test that asserts the 400.
    if ($idempotencyKey) { $extra += @('-H', "Idempotency-Key: $idempotencyKey") }

    $extra += @('--data-binary', "@$bodyFile")

    return Call $label $expected $extra
}

function XsrfToken {
    $line = Select-String -Path $jar -Pattern 'XSRF-TOKEN' | Select-Object -Last 1
    if (-not $line) { throw 'XSRF-TOKEN cookie was not set' }
    return [System.Uri]::UnescapeDataString((($line.Line -split "`t")[-1]))
}

Write-Host "`nunauthenticated" -ForegroundColor Cyan
Call 'GET  /api/v1/whoami (public)' 200 @("$Base/api/v1/whoami") | Out-Null
Call 'GET  /api/v1/employees' 401 @("$Base/api/v1/employees") | Out-Null

Write-Host "`nlogin" -ForegroundColor Cyan
Call 'GET  /sanctum/csrf-cookie' 204 @("$Base/sanctum/csrf-cookie") | Out-Null
Write-Host "        XSRF-TOKEN acquired ($((XsrfToken).Length) chars)" -ForegroundColor DarkGray

Post 'POST /api/v1/auth/login (wrong password)' 422 '/api/v1/auth/login' `
    '{"email":"admin@acme.test","password":"wrong"}' | Out-Null

Post 'POST /api/v1/auth/login' 200 '/api/v1/auth/login' `
    '{"email":"admin@acme.test","password":"password"}' | Out-Null

Write-Host "`nauthenticated reads" -ForegroundColor Cyan
Call 'GET  /api/v1/auth/user' 200 @("$Base/api/v1/auth/user") | Out-Null
Call 'GET  /api/v1/employees' 200 @("$Base/api/v1/employees?per_page=2") | Out-Null
Call 'GET  /api/v1/audit-logs' 200 @("$Base/api/v1/audit-logs?per_page=3") | Out-Null

Write-Host "`nasync writes + idempotency" -ForegroundColor Cyan
$payrollBody = '{"period_start":"2026-09-01","period_end":"2026-09-15","include_commission":true,"tax_rate":0.22}'

Post 'POST /api/v1/payroll/calculations (no key)' 400 '/api/v1/payroll/calculations' $payrollBody $null | Out-Null

$key = 'smoke-payroll-' + [guid]::NewGuid().ToString('N')
$payroll = Post 'POST /api/v1/payroll/calculations' 202 '/api/v1/payroll/calculations' $payrollBody $key
$requestId = ($payroll | ConvertFrom-Json).data.request_id

# The critical assertion: the same key must replay, not queue a second payroll run.
$replay = Post 'POST /api/v1/payroll/calculations (retry, same key)' 202 '/api/v1/payroll/calculations' $payrollBody $key
$replayId = ($replay | ConvertFrom-Json).data.request_id

if ($replayId -eq $requestId) {
    Write-Host "  PASS  retry replayed request_id $($requestId.Substring(0,8))... (no duplicate run)" -ForegroundColor Green
} else {
    $script:failures++
    Write-Host "  FAIL  retry produced a NEW request_id - a second payroll run was queued" -ForegroundColor Red
}

Post 'POST /api/v1/payroll/calculations (same key, changed payload)' 409 '/api/v1/payroll/calculations' `
    '{"period_start":"2026-09-01","period_end":"2026-09-30","include_commission":true,"tax_rate":0.22}' $key | Out-Null

Call 'GET  /api/v1/requests/{id}' 200 @("$Base/api/v1/requests/$requestId") | Out-Null
Call 'GET  /api/v1/payroll/calculations/{id} (worker has not run)' 404 `
    @("$Base/api/v1/payroll/calculations/$requestId") | Out-Null

Post 'POST /api/v1/sales/imports' 202 '/api/v1/sales/imports' `
    '{"source":"csv","rows":[{"external_id":"SO-9001","rep_email":"employee01@example.test","product":"Pro","amount":990.5,"sold_at":"2026-09-04T10:00:00Z"}]}' `
    ('smoke-sales-' + [guid]::NewGuid().ToString('N')) | Out-Null

Write-Host "`nauthorization" -ForegroundColor Cyan
# A viewer must not be able to run payroll. Fresh cookie jar per identity.
$viewerJar = Join-Path $env:TEMP 'sequifi-viewer.txt'
Remove-Item $viewerJar -ErrorAction SilentlyContinue
$viewerCommon = @('-s', '-b', $viewerJar, '-c', $viewerJar, '-H', "Host: $TenantHost",
    '-H', "Origin: $Origin", '-H', "Referer: $Origin/")

& curl.exe @viewerCommon "$Base/sanctum/csrf-cookie" | Out-Null
$viewerToken = [System.Uri]::UnescapeDataString(
    (((Select-String -Path $viewerJar -Pattern 'XSRF-TOKEN' | Select-Object -Last 1).Line -split "`t")[-1]))

[System.IO.File]::WriteAllText($bodyFile, '{"email":"viewer@acme.test","password":"password"}',
    (New-Object System.Text.UTF8Encoding($false)))
& curl.exe @viewerCommon -X POST "$Base/api/v1/auth/login" -H 'Content-Type: application/json' `
    -H "X-XSRF-TOKEN: $viewerToken" --data-binary "@$bodyFile" | Out-Null

$viewerToken = [System.Uri]::UnescapeDataString(
    (((Select-String -Path $viewerJar -Pattern 'XSRF-TOKEN' | Select-Object -Last 1).Line -split "`t")[-1]))
[System.IO.File]::WriteAllText($bodyFile, $payrollBody, (New-Object System.Text.UTF8Encoding($false)))

$raw = ((& curl.exe @viewerCommon -X POST "$Base/api/v1/payroll/calculations" `
        -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $viewerToken" `
        -H "Idempotency-Key: smoke-viewer-$([guid]::NewGuid().ToString('N'))" `
        --data-binary "@$bodyFile" -w "`n%{http_code}") -join "`n") -split "`n"
Show 'POST /api/v1/payroll/calculations as viewer' (($raw[0..($raw.Length - 2)] -join '').Trim()) $raw[-1].Trim() 403

$raw = ((& curl.exe @viewerCommon "$Base/api/v1/audit-logs" -w "`n%{http_code}") -join "`n") -split "`n"
Show 'GET  /api/v1/audit-logs as viewer' (($raw[0..($raw.Length - 2)] -join '').Trim()) $raw[-1].Trim() 403

Remove-Item $viewerJar -ErrorAction SilentlyContinue

Write-Host "`ncross-tenant isolation (same cookie jar, different tenant host)" -ForegroundColor Cyan
$raw = ((& curl.exe -s -b $jar -H 'Host: whiteknight.localhost' `
        -H 'Origin: http://whiteknight.localhost:5173' `
        -H 'Referer: http://whiteknight.localhost:5173/' `
        "$Base/api/v1/auth/user" -w "`n%{http_code}") -join "`n") -split "`n"
Show 'GET  /api/v1/auth/user as whiteknight' (($raw[0..($raw.Length - 2)] -join '').Trim()) $raw[-1].Trim() 401

Write-Host "`nlogout" -ForegroundColor Cyan
Call 'POST /api/v1/auth/logout' 200 @('-X', 'POST', "$Base/api/v1/auth/logout", '-H', "X-XSRF-TOKEN: $(XsrfToken)") | Out-Null
Call 'GET  /api/v1/auth/user' 401 @("$Base/api/v1/auth/user") | Out-Null

Remove-Item $jar, $bodyFile -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host "all checks passed" -ForegroundColor Green
    exit 0
}

Write-Host "$failures check(s) failed" -ForegroundColor Red
exit 1
