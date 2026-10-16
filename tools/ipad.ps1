# Helpers for testing Backcap on the jailbroken iPad over SSH (dot-source this file).
#   . .\tools\ipad.ps1
#   Test-IPadIdle                      (another session or the user may be using the iPad: check first)
#   Install-BackcapDeb -DebPath .\packages\run-123\com.samcejko.backcap_0.1.0_iphoneos-arm.deb [-Respring]
#   Get-BackcapLog
#   Get-BackcapDump
#   Invoke-BackcapCloseNow

$script:IPadKey = Join-Path $env:USERPROFILE '.ssh\ipad_ios6'
$script:IPadDefaultHost = '192.168.1.176'
$script:IPadLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPadLocalCfg) {
    try {
        $c = Get-Content $script:IPadLocalCfg -Raw | ConvertFrom-Json
        if ($c.ipad) { $script:IPadDefaultHost = $c.ipad }
    } catch {}
}

function Get-IPadSshArgs {
    @('-i', $script:IPadKey, '-oHostKeyAlgorithms=+ssh-rsa', '-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oBatchMode=yes', '-oLogLevel=ERROR',
      '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
}

function Invoke-IPad {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & ssh.exe @sshArgs "root@$IPadHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPad {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPadHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPad {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs -r "root@${IPadHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

function Test-IPadIdle {
    param([string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "launchctl list | grep UIKitApplication; echo ---; grep -c . /var/log/syslog 2>/dev/null"
}

function Install-BackcapDeb {
    param([Parameter(Mandatory = $true)][string]$DebPath, [switch]$Respring, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command 'killall Preferences 2>/dev/null; echo stopped' | Out-Null
    Copy-ToIPad -LocalPath $DebPath -RemotePath '/tmp/Backcap.deb' -IPadHost $IPadHost
    $out = Invoke-IPad -IPadHost $IPadHost -Command 'dpkg -i /tmp/Backcap.deb 2>&1 && echo DEB_OK; rm -f /tmp/Backcap.deb' | Out-String
    Write-Host $out
    if ($out -notmatch 'DEB_OK') { throw "Backcap was not installed" }
    if ($Respring) {
        Invoke-IPad -IPadHost $IPadHost -Command 'killall SpringBoard' | Out-Null
        Write-Host "Installed and triggered SpringBoard respring."
    } else {
        Write-Host "Installed. Settings pane works immediately on reopening Settings; pass -Respring to reload SpringBoard."
    }
}

function Get-BackcapLog {
    param([int]$Lines = 60, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "grep -e '\[Backcap\]' /var/log/syslog | sed -e :a -e '`$q;N;$($Lines + 1),`$D;ba'"
}

function Set-BackcapDebug {
    param([bool]$On = $true, [string]$IPadHost = $script:IPadDefaultHost)
    $cmd = if ($On) { 'touch /Library/Application\ Support/Backcap/debug && echo DEBUG_ON' } else { 'rm -f /Library/Application\ Support/Backcap/debug; echo DEBUG_OFF' }
    Invoke-IPad -IPadHost $IPadHost -Command $cmd
}

function Get-BackcapDump {
    param([string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "rm -f /tmp/backcap-dump.plist; notifyutil -p com.samcejko.backcap/dump; sleep 1; cat /tmp/backcap-dump.plist 2>/dev/null"
}

function Invoke-BackcapCloseNow {
    param([string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "rm -f /tmp/backcap-last-closed.plist; notifyutil -p com.samcejko.backcap/closeNow; sleep 1; cat /tmp/backcap-last-closed.plist 2>/dev/null"
}
