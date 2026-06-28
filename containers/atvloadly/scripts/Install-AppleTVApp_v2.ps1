# Install-AppleTVApp.ps1  v3.0
# Installs an IPA on Apple TV via atvloadly MCP API.
# IPA is copied to /etc/atvloadly (bind-mounted as /data in the container) and
# installed by passing the container-local path directly - no HTTP server needed.

param(
    [string]$IpaPath,
    [string]$PiHost     = "",
    [string]$PiUser     = "",
    [int]$AtvloadlyPort = 5533
)

$ErrorActionPreference = "Stop"

# --- UI Helpers ---

function Show-Banner {
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |      atvloadly IPA Installer  v3.0       |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Section([int]$n, [string]$msg) {
    Write-Host ""
    Write-Host ("  -- Step {0} > {1} {2}" -f $n, $msg, ("-" * [Math]::Max(2, 42 - $msg.Length))) -ForegroundColor DarkGray
}

function Write-Ok($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [!] $msg" -ForegroundColor Red; exit 1 }
function Write-Info($msg) { Write-Host "  [.] $msg" -ForegroundColor Gray }

function Prompt-Input([string]$label, [string]$example) {
    Write-Host "  " -NoNewline
    Write-Host $label -ForegroundColor Yellow -NoNewline
    if ($example) { Write-Host " (e.g. $example)" -ForegroundColor DarkGray -NoNewline }
    Write-Host ": " -NoNewline
    return (Read-Host)
}

function Show-Summary($device, $account, $ipaName, $state) {
    $status = if ($state -eq "completed") { "COMPLETED [OK]" } else { "FAILED [!!]" }
    $color  = if ($state -eq "completed") { "Green" } else { "Red" }
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ("  |  {0,-42}|" -f "Install $status") -ForegroundColor $color
    Write-Host ("  |  {0,-42}|" -f "IPA     : $ipaName") -ForegroundColor Gray
    Write-Host ("  |  {0,-42}|" -f "Device  : $($device.name)") -ForegroundColor Gray
    Write-Host ("  |  {0,-42}|" -f "Account : $($account.account_email)") -ForegroundColor Gray
    Write-Host "  +------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""
}

# --- MCP Helpers ---

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

# --- Main ---

Show-Banner

Write-Host "  Before continuing, make sure you have:" -ForegroundColor Yellow
Write-Host "    [1] Apple TV paired in atvloadly" -ForegroundColor DarkYellow
Write-Host "    [2] Apple account added in atvloadly" -ForegroundColor DarkYellow
Write-Host ""
$confirm = Read-Host "  Ready? (Y to continue)"
if ($confirm -notmatch '^[Yy]') { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
Write-Host ""

if (-not $PiHost)  { $PiHost  = Prompt-Input "Pi IP address" "<pi-ip>" }
if (-not $PiUser)  { $PiUser  = Prompt-Input "Pi username"   "pi" }
if (-not $IpaPath) { $IpaPath = Prompt-Input "Path to IPA"   "C:\path\to\YourApp.ipa" }

$IpaPath = $IpaPath.Trim('"').Trim("'")

$BaseUrl = "http://${PiHost}:${AtvloadlyPort}"
$McpUrl  = "$BaseUrl/mcp"
$Headers = @{ "Content-Type" = "application/json"; "Accept" = "application/json, text/event-stream" }

Write-Host ""
Write-Info "Pi     : ${PiUser}@${PiHost}"
Write-Info "Loadly : $BaseUrl"

# Step 1 - Validate IPA
Write-Section 1 "Validate IPA"
if (-not (Test-Path $IpaPath)) { Write-Err "File not found: $IpaPath" }
$IpaName = [System.IO.Path]::GetFileName($IpaPath)
$IpaMB   = [math]::Round((Get-Item $IpaPath).Length / 1MB, 1)
Write-Ok "$IpaName  ($IpaMB MB)"

# Step 2 - SCP to Pi
Write-Section 2 "Copy IPA to Pi"
Write-Info "Enter SSH password when prompted"
Write-Host ""
$RemotePath = "/etc/atvloadly/$IpaName"
scp $IpaPath "${PiUser}@${PiHost}:${RemotePath}"
if ($LASTEXITCODE -ne 0) { Write-Err "SCP failed. If permission denied: sudo chmod 777 /etc/atvloadly" }
Write-Ok "Copied -> $RemotePath"

# Container sees /etc/atvloadly as /data
$ContainerPath = "/data/$IpaName"

# Step 3 - MCP session
Write-Section 3 "Initialize MCP session"
$initBody = @{
    jsonrpc = "2.0"; method = "initialize"; id = 1
    params  = @{
        protocolVersion = "2024-11-05"
        capabilities    = @{}
        clientInfo      = @{ name = "ps-installer"; version = "3.0" }
    }
} | ConvertTo-Json -Depth 10
$initResp  = Invoke-WebRequest -Uri $McpUrl -Method POST -Headers $Headers -Body $initBody -UseBasicParsing
$SessionId = $initResp.Headers["mcp-session-id"]
if (-not $SessionId) { Write-Err "No session ID returned" }
Write-Ok "Session: $SessionId"

# Step 4 - Detect device
Write-Section 4 "Detect Apple TV"
$devData = (Parse-McpResponse (Invoke-Mcp $SessionId "tools/call" 2 @{ name = "get_device_list"; arguments = @{} }).Content).result.structuredContent
if ($devData.total -eq 0) { Write-Err "No paired Apple TV found" }
$device = $devData.available_devices[0]
Write-Ok "$($device.name)  [$($device.id)]"

# Step 5 - Detect account
Write-Section 5 "Detect Apple account"
$accData = (Parse-McpResponse (Invoke-Mcp $SessionId "tools/call" 3 @{ name = "get_account_list"; arguments = @{} }).Content).result.structuredContent
if ($accData.total -eq 0) { Write-Err "No Apple accounts found" }
$account = $accData.available_accounts[0]
Write-Ok "$($account.account_email)  [$($account.account_id)]"

# Step 6 - Queue install (container-local path, no HTTP server)
Write-Section 6 "Queue install"
$instResp = Invoke-Mcp $SessionId "tools/call" 4 @{
    name      = "install_app"
    arguments = @{ ipa_url = $ContainerPath; device_id = $device.id; account_id = $account.account_id }
}
$instData = (Parse-McpResponse $instResp.Content).result.structuredContent
Write-Ok "$($instData.status) - $($instData.message)"

# Step 7 - Poll status
Write-Section 7 "Wait for install"
$timeout = 600
$elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 5
    $elapsed   += 5
    $pct        = [int](($elapsed / $timeout) * 100)
    $statusData = (Parse-McpResponse (Invoke-Mcp $SessionId "tools/call" 5 @{ name = "get_install_status"; arguments = @{} }).Content).result.structuredContent
    Write-Progress -Activity "Installing $IpaName" -Status "[$elapsed s]  state=$($statusData.install_state)" -PercentComplete $pct
    if (-not $statusData.install_in_progress) { break }
}
Write-Progress -Activity "Installing" -Completed

Show-Summary $device $account $IpaName $statusData.install_state
