# Run the production validation loop against fixtures without requiring admin or network access.
BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-UploadLatency.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    $loop = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.VariablePath.UserPath -eq 'index' -and
        $node.Body.Extent.Text.Contains('ConvertFrom-Json')
    }, $true)
    if (-not $loop) { throw 'Could not locate the upload validation loop.' }
    $validateUploads = [scriptblock]::Create($loop.Extent.Text)
}

Describe 'Upload error diagnostics' {
    BeforeEach {
        $OutputDirectory = $TestDrive
        $ParallelUploads = 1
        $UploadMB = 40
        $uploadResults = [System.Collections.Generic.List[object]]::new()
        $timeoutMessage = 'Failed to connect to speed.cloudflare.com port 443 after 10001 ms: Timeout was reached'
        [ordered]@{
            http_code = 0
            exitcode = 28
            size_upload = 0
            time_total = 10.001992
            errormsg = $timeoutMessage
        } | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'upload-1.json')
        Set-Content (Join-Path $TestDrive 'upload-1.err') "curl: (28) $timeoutMessage"
    }

    It 'shows the curl connection error when the upload never connects' {
        { & $validateUploads } | Should -Throw '*Failed to connect to speed.cloudflare.com port 443 after 10001 ms: Timeout was reached*'
    }

    It 'includes the exit code, HTTP status, and transferred bytes' {
        { & $validateUploads } | Should -Throw '*curl exit 28; HTTP 0; sent 0/40000000 bytes*'
    }

    It 'marks the loaded latency as invalid when the upload fails' {
        { & $validateUploads } | Should -Throw '*Loaded-latency results are invalid for this run*'
    }

    It 'uses stderr when curl omits its JSON error message' {
        $result = Get-Content (Join-Path $TestDrive 'upload-1.json') -Raw | ConvertFrom-Json
        $result.errormsg = $null
        $result | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'upload-1.json')
        { & $validateUploads } | Should -Throw '*curl: (28) Failed to connect*'
    }

    It 'explains an incomplete upload even when curl reports no error' {
        @{http_code=200;exitcode=0;size_upload=100;time_total=1;errormsg=$null} |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'upload-1.json')
        Set-Content (Join-Path $TestDrive 'upload-1.err') ''
        { & $validateUploads } | Should -Throw '*sent 100/40000000 bytes*byte count did not match*'
    }

    It 'accepts a complete successful upload' {
        @{http_code=200;exitcode=0;size_upload=40000000;time_total=30;errormsg=$null} |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'upload-1.json')
        { & $validateUploads } | Should -Not -Throw
    }
}
