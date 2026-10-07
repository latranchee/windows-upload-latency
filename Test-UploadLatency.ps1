#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Measures idle and loaded ping with a temporary Windows upload cap.
.EXAMPLE
.\Test-UploadLatency.ps1
.EXAMPLE
.\Test-UploadLatency.ps1 -UploadMbps 10 -InterfaceAlias 'Wi-Fi'
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [double]$UploadMbps = 15,

    [string]$InterfaceAlias,

    [ValidateNotNullOrEmpty()]
    [string]$PingTarget = '1.1.1.1',

    [ValidateRange(1, 120)]
    [int]$IdleSeconds = 10,

    [ValidateRange(1, 100)]
    [int]$UploadMB = 40,

    [ValidateRange(1, 4)]
    [int]$ParallelUploads = 2,

    [ValidateRange(5, 300)]
    [int]$UploadTimeoutSeconds = 60,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot ('results/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'

function Add-NetworkSample {
    param([string]$Phase, [hashtable]$State)

    $tasks = @($State.Pings[0].SendPingAsync($PingTarget, 900), $State.Pings[1].SendPingAsync($State.Gateway, 900))
    try {
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks)
    } catch {
        Write-Verbose ('Ping probe failed: ' + $_.Exception.Message)
    }
    $now = $State.Clock.Elapsed.TotalSeconds
    $sent = $State.Network.GetIPStatistics().BytesSent
    $interval = $now - $State.PreviousTime
    $delta = [math]::Max(0, $sent - $State.PreviousBytes)
    $internetReply = if ($tasks[0].Status -eq 'RanToCompletion') { $tasks[0].Result } else { $null }
    $gatewayReply = if ($tasks[1].Status -eq 'RanToCompletion') { $tasks[1].Result } else { $null }
    $State.Samples.Add([pscustomobject]@{
        phase = $Phase
        seconds = $now
        intervalSeconds = $interval
        sentBytes = $delta
        uploadMbps = if ($interval -gt 0) { $delta * 8 / $interval / 1000000 } else { 0 }
        internetStatus = if ($internetReply) { [string]$internetReply.Status } else { 'Error' }
        internetMs = if ($internetReply -and $internetReply.Status -eq 'Success') { $internetReply.RoundtripTime } else { $null }
        gatewayStatus = if ($gatewayReply) { [string]$gatewayReply.Status } else { 'Error' }
        gatewayMs = if ($gatewayReply -and $gatewayReply.Status -eq 'Success') { $gatewayReply.RoundtripTime } else { $null }
    })
    $State.PreviousBytes = $sent
    $State.PreviousTime = $now
}

function Get-PhaseSummary {
    param([string]$Phase, [object[]]$Samples)

    $rows = @($Samples | Where-Object phase -EQ $Phase)
    $good = @($rows | Where-Object internetStatus -EQ 'Success' | ForEach-Object internetMs | Sort-Object)
    $seconds = ($rows | Measure-Object intervalSeconds -Sum).Sum
    $bytes = ($rows | Measure-Object sentBytes -Sum).Sum
    $median = $null
    $p95 = $null
    if ($good.Count -gt 0) {
        $median = ($good[[int][math]::Floor(($good.Count - 1) / 2)] + $good[[int][math]::Floor($good.Count / 2)]) / 2.0
        $p95 = $good[[int][math]::Ceiling($good.Count * 0.95) - 1]
    }
    [pscustomobject]@{
        Phase = $Phase
        DurationSeconds = [math]::Round($seconds, 2)
        UploadMbps = if ($seconds -gt 0) { [math]::Round($bytes * 8 / $seconds / 1000000, 2) } else { $null }
        MedianPingMs = $median
        P95PingMs = $p95
        FailedPings = $rows.Count - $good.Count
        TotalPings = $rows.Count
    }
}

# Select the lowest-cost connected IPv4 default route, or the requested adapter.
$routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | ForEach-Object {
    $route = $_
    $interface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex
    if ($interface.ConnectionState -eq 'Connected' -and (-not $InterfaceAlias -or $route.InterfaceAlias -eq $InterfaceAlias)) {
        [pscustomobject]@{
            InterfaceAlias = $route.InterfaceAlias
            InterfaceIndex = $route.InterfaceIndex
            Gateway = $route.NextHop
            Metric = $route.RouteMetric + $interface.InterfaceMetric
        }
    }
} | Sort-Object Metric)
if ($routes.Count -eq 0) { throw 'No connected IPv4 default route found. Check the connection or specify -InterfaceAlias.' }
$route = $routes[0]
$network = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object Name -EQ $route.InterfaceAlias
if (-not $network) { throw 'Could not read counters for the selected network adapter.' }
if ($route.Gateway -eq '0.0.0.0') { throw 'This route has no pingable gateway. Select a physical adapter with -InterfaceAlias.' }
$curlPath = (Get-Command curl.exe -CommandType Application).Source
Import-Module NetQos -ErrorAction Stop
$existing = @(Get-NetQosPolicy -PolicyStore ActiveStore)
if ($existing.Count -gt 0) {
    throw ('Existing QoS policies must be reviewed before testing: ' + (($existing | ForEach-Object Name) -join ', '))
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$policyName = 'UploadLatency-' + [guid]::NewGuid().ToString('N')
$policyCreated = $false
$policyRemoved = $false
$failure = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$processes = [System.Collections.Generic.List[object]]::new()
$uploadResults = [System.Collections.Generic.List[object]]::new()
$payloadPath = Join-Path ([IO.Path]::GetTempPath()) ($policyName + '.bin')
$state = @{
    Network = $network
    Gateway = $route.Gateway
    Pings = @([System.Net.NetworkInformation.Ping]::new(), [System.Net.NetworkInformation.Ping]::new())
    Clock = [Diagnostics.Stopwatch]::StartNew()
    Samples = [System.Collections.Generic.List[object]]::new()
    PreviousBytes = 0L
    PreviousTime = 0.0
}

try {
    # ActiveStore is temporary: it does not survive a reboot.
    New-NetQosPolicy -Name $policyName -PolicyStore ActiveStore -Default -NetworkProfile All -ThrottleRateActionBitsPerSecond ([uint64]($UploadMbps * 1000000)) | Out-Null
    $policyCreated = $true
    Write-Output "Temporary upload cap: $UploadMbps Mbps; adapter: $($route.InterfaceAlias); ping: $PingTarget"
    Write-Output "Policy: $policyName"
    Write-Output "Measuring $IdleSeconds seconds of idle latency..."
    $state.PreviousBytes = $network.GetIPStatistics().BytesSent
    $state.PreviousTime = $state.Clock.Elapsed.TotalSeconds
    $idleStart = $state.Clock.Elapsed.TotalSeconds
    do {
        Start-Sleep -Milliseconds 500
        Add-NetworkSample -Phase 'idle' -State $state
    } while (($state.Clock.Elapsed.TotalSeconds - $idleStart) -lt $IdleSeconds)

    # A newly created, zero-filled file contains no user data.
    $payload = [IO.File]::Open($payloadPath, [IO.FileMode]::CreateNew)
    try { $payload.SetLength([long]$UploadMB * 1000000) } finally { $payload.Dispose() }
    Write-Output "Uploading $ParallelUploads x $UploadMB MB of synthetic data to Cloudflare..."
    $uploadStart = $state.Clock.Elapsed.TotalSeconds
    $state.PreviousBytes = $network.GetIPStatistics().BytesSent
    $state.PreviousTime = $uploadStart
    foreach ($index in 1..$ParallelUploads) {
        $outPath = Join-Path $OutputDirectory "upload-$index.json"
        $errPath = Join-Path $OutputDirectory "upload-$index.err"
        # Quote the file argument because Start-Process joins ArgumentList into a command line.
        $curlArguments = @('--silent', '--show-error', '--http1.1', '--max-time', $UploadTimeoutSeconds, '--connect-timeout', '10', '--request', 'POST', '--data-binary', ('"@' + $payloadPath + '"'), '--output', 'NUL', '--write-out', '%{json}', 'https://speed.cloudflare.com/__up')
        $process = Start-Process -FilePath $curlPath -ArgumentList $curlArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $processes.Add($process)
    }
    do {
        Start-Sleep -Milliseconds 500
        Add-NetworkSample -Phase 'upload' -State $state
        $running = @($processes | Where-Object { -not $_.HasExited })
    } while ($running.Count -gt 0 -and ($state.Clock.Elapsed.TotalSeconds - $uploadStart) -lt ($UploadTimeoutSeconds + 5))
    if ($running.Count -gt 0) { throw 'Upload processes exceeded the test deadline.' }

    foreach ($index in 1..$ParallelUploads) {
        $result = Get-Content -LiteralPath (Join-Path $OutputDirectory "upload-$index.json") -Raw | ConvertFrom-Json
        $uploadResults.Add([pscustomobject]@{
            stream = $index
            httpStatus = $result.http_code
            exitCode = $result.exitcode
            bytesUploaded = $result.size_upload
            durationSeconds = $result.time_total
            error = $result.errormsg
        })
        if ($result.http_code -ne 200 -or $result.exitcode -ne 0 -or $result.size_upload -ne ([long]$UploadMB * 1000000)) {
            throw "Upload $index failed or was incomplete. See upload-$index.json and upload-$index.err."
        }
    }
} catch {
    $failure = $_
} finally {
    # Stop only processes launched by this script. Restore QoS before saving results.
    foreach ($process in $processes) {
        try {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction Stop }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($policyCreated) {
        try {
            Remove-NetQosPolicy -Name $policyName -PolicyStore ActiveStore -Confirm:$false
            $remaining = @(Get-NetQosPolicy -PolicyStore ActiveStore | Where-Object Name -EQ $policyName)
            if ($remaining.Count -gt 0) { throw 'The temporary QoS policy is still present.' }
            $policyRemoved = $true
        } catch {
            $cleanupErrors.Add("Could not remove QoS policy '$policyName': $($_.Exception.Message)")
        }
    }
    foreach ($ping in $state.Pings) { $ping.Dispose() }
    try {
        if (Test-Path -LiteralPath $payloadPath) { Remove-Item -LiteralPath $payloadPath }
    } catch { $cleanupErrors.Add($_.Exception.Message) }

    $summaries = @(Get-PhaseSummary -Phase 'idle' -Samples $state.Samples.ToArray(); Get-PhaseSummary -Phase 'upload' -Samples $state.Samples.ToArray())
    $report = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        requestedUploadMbps = $UploadMbps
        interfaceAlias = $route.InterfaceAlias
        pingTarget = $PingTarget
        gateway = $route.Gateway
        uploadEndpoint = 'https://speed.cloudflare.com/__up'
        policyName = $policyName
        policyRemoved = $policyRemoved
        error = if ($failure) { $failure.Exception.Message } else { $null }
        cleanupErrors = $cleanupErrors.ToArray()
        summary = $summaries
        uploads = $uploadResults.ToArray()
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
    ConvertTo-Json -InputObject $state.Samples.ToArray() -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'samples.json') -Encoding UTF8
    $summaries | Format-Table Phase, UploadMbps, MedianPingMs, P95PingMs, FailedPings, TotalPings -AutoSize | Out-Host
    if ($policyRemoved) { Write-Output 'Temporary cap removed. Normal upload settings restored.' }
    Write-Output "Results saved to: $OutputDirectory"
}
if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
if ($failure) { throw $failure }
