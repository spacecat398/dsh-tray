# =============================================================================
# setup-portproxy.ps1 - Windows-side port forwarding for dsh-tray
#
# Topology (win port != wsl port):
#   Windows 127.0.0.1:3080  (netsh portproxy listens here)
#        |  connectaddress=127.0.0.1 -> WSL2 localhost forward
#        v
#   WSL   127.0.0.1:3088  (dsh web actually listens here)
#
# connectaddress=127.0.0.1 (not the WSL IP) so the rule survives WSL restarts.
# The rule persists in the Windows registry across reboots.
#
# MUST run as Administrator (UAC). Usage:
#   powershell -ExecutionPolicy Bypass -File setup-portproxy.ps1        # add
#   powershell -ExecutionPolicy Bypass -File setup-portproxy.ps1 -Remove # remove
# =============================================================================
param(
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$ListenAddress  = "127.0.0.1"
$ListenPort     = 3080
$ConnectAddress = "127.0.0.1"
$ConnectPort    = 3088

if ($Remove) {
    netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$ListenPort
    if ($LASTEXITCODE -ne 0) { throw "netsh delete failed" }
    Write-Host "Removed: ${ListenAddress}:${ListenPort} -> ${ConnectAddress}:${ConnectPort}"
}
else {
    netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectaddress=$ConnectAddress connectport=$ConnectPort
    if ($LASTEXITCODE -ne 0) { throw "netsh add failed (port already in use?)" }
    Write-Host "Added:   ${ListenAddress}:${ListenPort} -> ${ConnectAddress}:${ConnectPort} (dsh web in WSL)"
}

Write-Host ""
Write-Host "Current portproxy rules:"
netsh interface portproxy show all
