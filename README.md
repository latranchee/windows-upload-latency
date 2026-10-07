# Windows upload latency test

Measure ping while Windows uploads at a capped rate. The default is **15 Mbps** with two simultaneous uploads, so you can compare idle latency with latency under upload load.

Uses Windows QoS, PowerShell, and the built-in `curl.exe`. No bandwidth-limiting app is needed. Tested on Windows 11 Pro.

## Run

1. Download this repository or clone it:

   ```powershell
   git clone https://github.com/latranchee/windows-upload-latency.git
   cd windows-upload-latency
   ```

2. Open **PowerShell as Administrator**, then change into the repository folder.

3. Run:

   ```powershell
   .\Test-UploadLatency.ps1
   ```

The script creates a temporary whole-computer outbound QoS policy, measures 10 seconds of idle ping, and uploads two generated 40 MB files to Cloudflare's speed-test endpoint. It samples ping to `1.1.1.1` and your gateway, measures the selected adapter's combined upload traffic, prints a summary, and removes its policy and generated payload.

The default transfers 80 MB of synthetic data. Allow about a minute at 15 Mbps. No personal files are uploaded.

If a downloaded script is blocked, review it and run `Unblock-File .\Test-UploadLatency.ps1`. Your organization's PowerShell execution policy may still restrict scripts.

## Options

```powershell
# Use a different cap.
.\Test-UploadLatency.ps1 -UploadMbps 10

# Choose an adapter explicitly (list names with Get-NetAdapter).
.\Test-UploadLatency.ps1 -InterfaceAlias 'Wi-Fi'

# A shorter test: two 5 MB uploads after a 5-second baseline.
.\Test-UploadLatency.ps1 -IdleSeconds 5 -UploadMB 5

# Choose another ping destination.
.\Test-UploadLatency.ps1 -PingTarget 8.8.8.8
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `UploadMbps` | `15` | Requested upload cap in decimal megabits/second. |
| `InterfaceAlias` | Automatic | Adapter with the lowest-cost connected IPv4 default route. |
| `PingTarget` | `1.1.1.1` | Internet destination for ICMP ping. |
| `IdleSeconds` | `10` | Baseline measurement duration. |
| `UploadMB` | `40` | Decimal megabytes per upload. |
| `ParallelUploads` | `2` | Number of simultaneous uploads. |
| `UploadTimeoutSeconds` | `60` | Maximum duration of each upload. Increase for lower caps. |
| `OutputDirectory` | `results/<unique-run>` | Folder for JSON results and curl diagnostics. |

## Read the results

- **UploadMbps** is the selected adapter's measured outgoing rate, including background traffic and protocol overhead. Check that it is close to the requested cap during the upload phase.
- **MedianPingMs / P95PingMs** show typical latency and its 95th percentile. Compare the idle and upload rows. Failed pings are reported separately and excluded from these latency values.
- **FailedPings / TotalPings** show unanswered or failed probes. ICMP can be filtered or deprioritized, so these do not by themselves prove application packet loss.

`summary.json` contains the summary and cleanup status. `samples.json` contains individual measurements, including gateway ping. The `results/` folder is excluded from Git; results can contain local network addresses and curl connection details.

This measures ICMP latency during a capped upload. Browser speed tests may use different servers and latency methods. A 15 Mbps load only saturates an Internet connection whose usable upload capacity is around that rate. Choose a cap and payload size appropriate to what you want to test.

## Connection errors

`curl exit 28`, `HTTP 0`, and `sent 0/... bytes` with a "Failed to connect" message mean the upload never connected. The ping samples from that failed run do not measure upload-loaded latency. The script still attempts to remove its temporary cap and records the outcome as `policyRemoved` in `summary.json`.

With the test stopped, check connectivity without the cap:

```powershell
curl.exe -I --connect-timeout 20 --max-time 25 'https://speed.cloudflare.com/__down?bytes=0'
curl.exe -4 -I --connect-timeout 20 --max-time 25 'https://speed.cloudflare.com/__down?bytes=0'
```

The second command forces IPv4. Differences between the two results can help diagnose address-family routing issues. These checks use the same host but a different request from the upload, so a successful check does not guarantee that POST uploads will work. The upload's connection timeout is 10 seconds; `UploadTimeoutSeconds` controls its overall duration.

For other failures, the terminal includes curl's error and the results folder. `upload-1.err` and `upload-1.json` contain the original diagnostics. Do not publish these files without reviewing the network details they contain.

## Cleanup and requirements

Use Windows with the `NetQos` module, an IPv4 default route, and `curl.exe` supporting `--write-out '%{json}'` (curl 7.70+). The script refuses to start when existing QoS policies are active. It does not change those policies. With VPNs or multiple active adapters, verify the selected route and measured rate; the throughput counter covers the selected adapter.

The cap applies to outgoing traffic from the whole computer while the script runs. Uploads from other apps and traffic to local devices can also be affected. The script removes its own policy on completion, errors, or normal Ctrl+C cancellation.

If PowerShell is forcibly terminated, the `ActiveStore` policy can remain until reboot. To remove it sooner, open an administrator PowerShell and find the policy printed at startup:

```powershell
Get-NetQosPolicy -PolicyStore ActiveStore | Where-Object Name -Like 'UploadLatency-*'

# Substitute the exact name from this test run.
Remove-NetQosPolicy -Name 'UploadLatency-<id>' -PolicyStore ActiveStore -Confirm:$false
```

References: [Windows QoS policies](https://learn.microsoft.com/en-us/powershell/module/netqos/new-netqospolicy), [Cloudflare's speed-test endpoint](https://github.com/cloudflare/speedtest).
