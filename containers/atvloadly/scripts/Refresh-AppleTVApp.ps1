# Refresh-AppleTVApp.ps1  v1.0
# Forces a real refresh of installed apps via atvloadly's MCP API, waits for
# completion, then sends a status notification (success AND failure) via
# atvloadly's existing notification config - unlike the built-in scheduled
# task, which only notifies on failure.

param(
    [string]$PiHost     = "<pi-ip>",
    [int]$AtvloadlyPort = 5533,
    [int]$AppId         = 0   # 0 = refresh all expired enabled apps; set to force a specific app id
)

$ErrorActionPreference = "Stop"

$BaseUrl = "http://${PiHost}:${AtvloadlyPort}"
$McpUrl  = "$BaseUrl/mcp"
$Headers = @{ "Content-Type" = "application/json"; "Accept" = "application/json, text/event-stream" }

function Write-Ok($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [!] $msg" -ForegroundColor Red; exit 1 }
function Write-Info($msg) { Write-Host "  [.] $msg" -ForegroundColor Gray }

function Parse-McpResponse($raw) {
    foreach ($line in $raw -split "`n") {
        if ($line.StartsWith("data:")) {
            return ($line.Substring(5).Trim() | ConvertFrom-Json)
        }
    }
    throw "No SSE data line in response"
}

function Invoke-Mcp($SessionId, $method, $id, $params = @{}) {
    $body = @{ jsonrpc = "2.0"; method = $method; id = $id; params = $params } | ConvertTo-Json -Depth 10
    $h = $Headers.Clone()
    if ($SessionId) { $h["mcp-session-id"] = $SessionId }
    return Invoke-WebRequest -Uri $McpUrl -Method POST -Headers $h -Body $body -UseBasicParsing
}

Write-Host ""
Write-Host "  atvloadly Refresh + Notify" -ForegroundColor Cyan
Write-Host ""

# Step 1 - MCP session
Write-Info "Initializing MCP session..."
$initBody = @{
    jsonrpc = "2.0"; method = "initialize"; id = 1
    params  = @{
        protocolVersion = "2024-11-05"
        capabilities    = @{}
        clientInfo      = @{ name = "ps-refresher"; version = "1.0" }
    }
} | ConvertTo-Json -Depth 10
$initResp  = Invoke-WebRequest -Uri $McpUrl -Method POST -Headers $Headers -Body $initBody -UseBasicParsing
$SessionId = $initResp.Headers["mcp-session-id"]
if (-not $SessionId) { Write-Err "No session ID returned" }
Write-Ok "Session: $SessionId"

# Step 2 - Queue refresh
Write-Info "Queuing refresh (app_id=$AppId, 0=all expired)..."
$refreshArgs = @{}
if ($AppId -gt 0) { $refreshArgs["app_id"] = $AppId }
$refreshResp = (Parse-McpResponse (Invoke-Mcp $SessionId "tools/call" 2 @{ name = "refresh_app"; arguments = $refreshArgs }).Content).result.structuredContent
Write-Ok "$($refreshResp.mode): queued=$($refreshResp.queued_count) skipped=$($refreshResp.skipped_count) - $($refreshResp.message)"

if ($refreshResp.queued_count -eq 0) {
    Write-Info "Nothing was queued (no expired apps, or invalid app_id). Exiting."
    exit 0
}

# Step 3 - Poll until done
Write-Info "Waiting for refresh to complete..."
$timeout = 300
$elapsed = 0
$status  = $null
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    $statusArgs = @{}
    if ($AppId -gt 0) { $statusArgs["app_id"] = $AppId }
    $status = (Parse-McpResponse (Invoke-Mcp $SessionId "tools/call" 3 @{ name = "get_refresh_status"; arguments = $statusArgs }).Content).result.structuredContent
    Write-Host "  [$elapsed s] in_progress=$($status.summary.in_progress_count) success=$($status.summary.success_count) failed=$($status.summary.failed_count)" -ForegroundColor DarkGray
    if ($status.summary.in_progress_count -eq 0) { break }
}

# Step 4 - Build report and notify (always, regardless of outcome)
$lines = foreach ($item in $status.items) {
    $mark = if ($item.refresh_state -eq "completed_success") { "OK" } else { "FAIL($($item.last_error_code))" }
    "$($item.ipa_name): $mark  exp=$($item.last_refresh_at)"
}
$report = ($lines -join " | ")
$title  = "atvloadly refresh: $($status.summary.success_count) ok / $($status.summary.failed_count) failed"

Write-Host ""
Write-Ok $title
$lines | ForEach-Object { Write-Host "    $_" }

$encTitle = [uri]::EscapeDataString($title)
$encDesc  = [uri]::EscapeDataString($report)
Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/notify/send?title=$encTitle&desc=$encDesc" | Out-Null
Write-Ok "Notification sent."
