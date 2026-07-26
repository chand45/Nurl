# Nurl Installation Script for Windows
# Usage: irm https://raw.githubusercontent.com/chand45/Nurl/main/install.ps1 | iex

[CmdletBinding()]
param()

& {
    $ErrorActionPreference = "Stop"
    $hasOutputRendering = $null -ne $PSStyle
    $previousOutputRendering = if ($hasOutputRendering) { $PSStyle.OutputRendering } else { $null }
    if ($hasOutputRendering) {
        $PSStyle.OutputRendering = "PlainText"
    }

    try {
    function Get-NurlTextFile {
        param([Parameter(Mandatory)][string]$Path)

        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $offset = 0
        $encoding = $null
        $preamble = [byte[]]@()

        if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
            $encoding = [System.Text.UTF32Encoding]::new($true, $true, $true)
            $offset = 4
            $preamble = [byte[]]$bytes[0..3]
        } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
            $encoding = [System.Text.UTF32Encoding]::new($false, $true, $true)
            $offset = 4
            $preamble = [byte[]]$bytes[0..3]
        } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = [System.Text.UTF8Encoding]::new($true, $true)
            $offset = 3
            $preamble = [byte[]]$bytes[0..2]
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
            $offset = 2
            $preamble = [byte[]]$bytes[0..1]
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
            $offset = 2
            $preamble = [byte[]]$bytes[0..1]
        } else {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        }

        try {
            $text = if ($bytes.Length -eq $offset) {
                ""
            } else {
                $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
            }
        } catch {
            throw "Nushell config contains invalid or unsupported text encoding: $Path"
        }
        [pscustomobject]@{
            Text = $text
            Encoding = $encoding
            Preamble = $preamble
            Bytes = $bytes
        }
    }

    function ConvertTo-NurlBytes {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [Parameter(Mandatory)]$File
        )

        $content = $File.Encoding.GetBytes($Text)
        $result = [byte[]]::new($File.Preamble.Length + $content.Length)
        if ($File.Preamble.Length -gt 0) {
            [System.Array]::Copy($File.Preamble, 0, $result, 0, $File.Preamble.Length)
        }
        if ($content.Length -gt 0) {
            [System.Array]::Copy($content, 0, $result, $File.Preamble.Length, $content.Length)
        }
        return ,$result
    }

    function Get-NurlLineRecords {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($match in [regex]::Matches($Text, '([^\r\n]*)(\r\n|\n|\r|$)')) {
            if ($match.Length -eq 0) {
                continue
            }
            $records.Add([pscustomobject]@{
                Body = $match.Groups[1].Value
                Eol = $match.Groups[2].Value
            })
        }
        $records
    }

    function Test-NurlLegacySource {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
        $trimmed = $Line.Trim()
        $trimmed -ceq 'source ~/.nurl/api.nu' -or
            $trimmed -ceq 'source "~/.nurl/api.nu"' -or
            $trimmed -ceq 'source $"($env.HOME)/.nurl/api.nu"'
    }

    function New-NurlInstallConfig {
        param([Parameter(Mandatory)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $file = [pscustomobject]@{
                Encoding = $encoding
                Preamble = [byte[]]@()
            }
            $text = "# >>> nurl >>>`r`nsource ~/.nurl/api.nu`r`n# <<< nurl <<<`r`n"
            return [pscustomobject]@{ Changed = $true; Bytes = (ConvertTo-NurlBytes $text $file) }
        }

        $file = Get-NurlTextFile $Path
        $records = @(Get-NurlLineRecords $file.Text)
        $ownedStart = -1
        $ownedEnd = -1
        $inside = $false
        for ($index = 0; $index -lt $records.Count; $index++) {
            $line = $records[$index].Body.Trim()
            if ($line -ceq "# >>> nurl >>>") {
                if ($inside -or $ownedStart -ge 0) {
                    throw "Nushell config contains an invalid Nurl sentinel block: $Path"
                }
                $inside = $true
                $ownedStart = $index
            } elseif ($line -ceq "# <<< nurl <<<") {
                if (-not $inside) {
                    throw "Nushell config contains an unmatched Nurl sentinel: $Path"
                }
                $inside = $false
                $ownedEnd = $index
            }
        }
        if ($inside) {
            throw "Nushell config contains an unterminated Nurl sentinel block: $Path"
        }
        if ($ownedStart -ge 0 -and $ownedEnd -ge $ownedStart) {
            return [pscustomobject]@{ Changed = $false; Bytes = $file.Bytes }
        }

        $newline = [Environment]::NewLine
        foreach ($record in $records) {
            if ($record.Eol.Length -gt 0) {
                $newline = $record.Eol
                break
            }
        }
        $endedWithNewline = $file.Text.EndsWith("`n") -or $file.Text.EndsWith("`r")
        $output = [System.Collections.Generic.List[object]]::new()
        $inserted = $false
        foreach ($record in $records) {
            if (Test-NurlLegacySource $record.Body) {
                if (-not $inserted) {
                    if ($output.Count -gt 0 -and $output[$output.Count - 1].Body.Trim() -ceq "# Nurl - Terminal API Client") {
                        $output.RemoveAt($output.Count - 1)
                    }
                    $output.Add([pscustomobject]@{ Body = "# >>> nurl >>>"; Eol = $newline })
                    $output.Add([pscustomobject]@{ Body = "source ~/.nurl/api.nu"; Eol = $newline })
                    $output.Add([pscustomobject]@{ Body = "# <<< nurl <<<"; Eol = $record.Eol })
                    $inserted = $true
                }
                continue
            }
            $output.Add([pscustomobject]@{ Body = $record.Body; Eol = $record.Eol })
        }

        if (-not $inserted) {
            if ($output.Count -gt 0 -and $output[$output.Count - 1].Eol.Length -eq 0) {
                $output[$output.Count - 1].Eol = $newline
            }
            $output.Add([pscustomobject]@{ Body = "# >>> nurl >>>"; Eol = $newline })
            $output.Add([pscustomobject]@{ Body = "source ~/.nurl/api.nu"; Eol = $newline })
            $output.Add([pscustomobject]@{ Body = "# <<< nurl <<<"; Eol = $(if ($endedWithNewline -or $records.Count -eq 0) { $newline } else { "" }) })
        }

        $builder = [System.Text.StringBuilder]::new()
        foreach ($record in $output) {
            [void]$builder.Append($record.Body)
            [void]$builder.Append($record.Eol)
        }
        [pscustomobject]@{
            Changed = $true
            Bytes = ConvertTo-NurlBytes $builder.ToString() $file
        }
    }

    function Write-NurlUtf8 {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content
        )
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Assert-NurlSafeDirectoryChain {
        param([Parameter(Mandatory)][string]$Path)

        $current = [System.IO.Path]::GetFullPath($Path)
        while (-not [string]::IsNullOrEmpty($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to install through a reparse-point directory: $current"
                }
                if (-not $item.PSIsContainer) {
                    throw "Expected an install directory but found another item: $current"
                }
            }
            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
                break
            }
            $current = $parent
        }
    }

    function Invoke-NurlCapture {
        param(
            [Parameter(Mandatory)][string]$FilePath,
            [Parameter()][string[]]$Arguments = @()
        )
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = @(& $FilePath @Arguments 2>$null)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
    }

    function Invoke-NurlInstall {
        $NurlHome = Join-Path $env:USERPROFILE ".nurl"
        $RepoUrl = "https://raw.githubusercontent.com/chand45/Nurl/main"
        $MinimumCurlVersion = [version]"7.75.0"
        $MinimumNushellVersion = [version]"0.89.0"
        $Modules = @("mod.nu", "http.nu", "auth.nu", "vars.nu", "history.nu", "chain.nu", "tui.nu", "log.nu", "resource-path.nu", "command-error.nu", "curl-capability.nu", "string-compat.nu")
        $Environments = @("default.nuon", "dev.nuon", "staging.nuon")
        $Requests = @("create-post.nuon", "delete-post.nuon", "get-comments.nuon", "get-post.nuon", "get-posts.nuon", "get-users.nuon", "update-post.nuon")

        Write-Host "Installing Nurl - Terminal API Client" -ForegroundColor Blue
        Write-Host ""

        $nuPath = Get-Command nu -ErrorAction SilentlyContinue
        if (-not $nuPath) {
            throw "Nushell is not installed. Install Nushell $MinimumNushellVersion or newer: https://www.nushell.sh/book/installation.html"
        }
        $nuVersionProbe = Invoke-NurlCapture -FilePath $nuPath.Source -Arguments @("--version")
        if ($nuVersionProbe.ExitCode -ne 0 -or $nuVersionProbe.Output.Count -eq 0) {
            throw "Could not determine the installed Nushell version."
        }
        $nuVersionText = ([string]$nuVersionProbe.Output[0]).Trim()
        if ($nuVersionText -cnotmatch '^(\d+)\.(\d+)\.(\d+)(?:[^0-9.].*)?$') {
            throw "Could not determine the installed Nushell version."
        }
        $nuVersion = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
        if ($nuVersion -lt $MinimumNushellVersion) {
            throw "Nushell $MinimumNushellVersion or newer is required (found $nuVersion)."
        }

        $curlPath = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $curlPath) {
            throw "curl $MinimumCurlVersion or newer is required."
        }
        $curlVersionProbe = Invoke-NurlCapture -FilePath $curlPath.Source -Arguments @("--version")
        if ($curlVersionProbe.ExitCode -ne 0 -or $curlVersionProbe.Output.Count -eq 0) {
            throw "Could not determine the installed curl version."
        }
        $curlVersionText = [string]$curlVersionProbe.Output[0]
        if ($curlVersionText -cnotmatch '^curl(?:\.exe)?\s+(\d+)\.(\d+)\.(\d+)(?:[^0-9.].*)?$') {
            throw "Could not determine the installed curl version."
        }
        $curlVersion = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
        if ($curlVersion -lt $MinimumCurlVersion) {
            throw "curl $MinimumCurlVersion or newer is required (found $curlVersion)."
        }

        $configProbe = Invoke-NurlCapture -FilePath $nuPath.Source -Arguments @("--no-config-file", "-c", '$nu.default-config-dir')
        $NushellConfigDir = if ($configProbe.ExitCode -eq 0 -and $configProbe.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$configProbe.Output[0])) {
            ([string]$configProbe.Output[0]).Trim()
        } elseif (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
            Join-Path $env:XDG_CONFIG_HOME "nushell"
        } elseif (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            Join-Path $env:APPDATA "nushell"
        } else {
            Join-Path $env:USERPROFILE "AppData\Roaming\nushell"
        }
        $ConfigPath = Join-Path $NushellConfigDir "config.nu"
        foreach ($installDirectory in @(
            $NurlHome,
            (Join-Path $NurlHome "nu_modules"),
            (Join-Path $NurlHome "collections"),
            (Join-Path $NurlHome "chains"),
            (Join-Path $NurlHome "history"),
            $NushellConfigDir
        )) {
            Assert-NurlSafeDirectoryChain $installDirectory
        }
        $existingConfig = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $existingConfig -and ($existingConfig.PSIsContainer -or (($existingConfig.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
            throw "Refusing to replace non-file Nushell config path: $ConfigPath"
        }
        $IsUpdate = Test-Path -LiteralPath $NurlHome -PathType Container
        if ($IsUpdate) {
            Write-Host "Existing installation detected. Updating..." -ForegroundColor Yellow
        }

        $StageRoot = Join-Path $env:USERPROFILE (".nurl-stage-" + [guid]::NewGuid().ToString("N"))
        $PayloadRoot = Join-Path $StageRoot "install"
        $RollbackRoot = Join-Path $StageRoot "rollback"
        $promotionStarted = $false
        $committed = $false
        $freshPromoted = $false
        $rollbackRecords = [System.Collections.Generic.List[object]]::new()
        $createdDirectories = [System.Collections.Generic.List[string]]::new()
        $rollbackState = [pscustomobject]@{ Failed = $false }

        function Ensure-TrackedDirectory {
            param([Parameter(Mandatory)][string]$Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                $missing = [System.Collections.Generic.List[string]]::new()
                $current = $Path
                while (-not (Test-Path -LiteralPath $current -PathType Container)) {
                    $missing.Add($current)
                    $parent = Split-Path -Parent $current
                    if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
                        break
                    }
                    $current = $parent
                }
                [void][System.IO.Directory]::CreateDirectory($Path)
                for ($index = $missing.Count - 1; $index -ge 0; $index--) {
                    $createdDirectories.Add($missing[$index])
                }
            }
        }

        function Promote-NurlFile {
            param(
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Destination,
                [Parameter(Mandatory)][string]$BackupName
            )
            Ensure-TrackedDirectory (Split-Path -Parent $Destination)
            $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                if ($existing.PSIsContainer -or (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw "Refusing to replace non-file install path: $Destination"
                }
                $backup = Join-Path $RollbackRoot $BackupName
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
                Copy-Item -LiteralPath $Destination -Destination $backup -Force
                $rollbackRecords.Add([pscustomobject]@{ Destination = $Destination; Backup = $backup; Created = $false })
            } else {
                $rollbackRecords.Add([pscustomobject]@{ Destination = $Destination; Backup = $null; Created = $true })
            }
            Move-Item -LiteralPath $Source -Destination $Destination -Force
        }

        function Promote-NurlFileIfAbsent {
            param(
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Destination,
                [Parameter(Mandatory)][string]$BackupName
            )
            if ($null -eq (Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue)) {
                Promote-NurlFile $Source $Destination $BackupName
            }
        }

        function Undo-NurlPromotion {
            $oldPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Stop"
                for ($index = $rollbackRecords.Count - 1; $index -ge 0; $index--) {
                    $record = $rollbackRecords[$index]
                    try {
                        if ($null -ne (Get-Item -LiteralPath $record.Destination -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $record.Destination -Recurse -Force -ErrorAction Stop
                        }
                        if (-not $record.Created) {
                            Move-Item -LiteralPath $record.Backup -Destination $record.Destination -Force -ErrorAction Stop
                        }
                    } catch {
                        $rollbackState.Failed = $true
                        [Console]::Error.WriteLine("Warning: rollback could not restore '$($record.Destination)': $($_.Exception.Message)")
                    }
                }
                if ($freshPromoted) {
                    try {
                        Remove-Item -LiteralPath $NurlHome -Recurse -Force -ErrorAction Stop
                    } catch {
                        $rollbackState.Failed = $true
                        [Console]::Error.WriteLine("Warning: rollback could not remove '$NurlHome': $($_.Exception.Message)")
                    }
                }
                for ($index = $createdDirectories.Count - 1; $index -ge 0; $index--) {
                    $directory = $createdDirectories[$index]
                    if ([System.IO.Directory]::Exists($directory)) {
                        try {
                            [System.IO.Directory]::Delete($directory, $false)
                        } catch [System.IO.IOException] {
                            # Concurrent or user-created content is preserved.
                        } catch {
                            $rollbackState.Failed = $true
                            [Console]::Error.WriteLine("Warning: rollback could not remove directory '$directory': $($_.Exception.Message)")
                        }
                    }
                }
            } finally {
                $ErrorActionPreference = $oldPreference
            }
        }

        try {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "nu_modules"))
            [void][System.IO.Directory]::CreateDirectory($RollbackRoot)

            Write-Host "[1/4] Staging Nurl payloads..."
            Invoke-WebRequest -Uri "$RepoUrl/api.nu" -OutFile (Join-Path $PayloadRoot "api.nu") -UseBasicParsing
            foreach ($module in $Modules) {
                Invoke-WebRequest -Uri "$RepoUrl/nu_modules/$module" -OutFile (Join-Path $PayloadRoot "nu_modules\$module") -UseBasicParsing
            }

            [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "collections"))
            [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "chains"))
            [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "history"))
            if (-not (Test-Path -LiteralPath (Join-Path $NurlHome "collections\jsonplaceholder"))) {
                Write-Host "  Staging example collection: jsonplaceholder"
                [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "collections\jsonplaceholder\environments"))
                [void][System.IO.Directory]::CreateDirectory((Join-Path $PayloadRoot "collections\jsonplaceholder\requests"))
                Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/collection.nuon" -OutFile (Join-Path $PayloadRoot "collections\jsonplaceholder\collection.nuon") -UseBasicParsing
                Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/meta.nuon" -OutFile (Join-Path $PayloadRoot "collections\jsonplaceholder\meta.nuon") -UseBasicParsing
                foreach ($environment in $Environments) {
                    Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/environments/$environment" -OutFile (Join-Path $PayloadRoot "collections\jsonplaceholder\environments\$environment") -UseBasicParsing
                }
                foreach ($request in $Requests) {
                    Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/requests/$request" -OutFile (Join-Path $PayloadRoot "collections\jsonplaceholder\requests\$request") -UseBasicParsing
                }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $NurlHome "chains\example-workflow.nuon"))) {
                Write-Host "  Staging example chain: example-workflow"
                Invoke-WebRequest -Uri "$RepoUrl/chains/example-workflow.nuon" -OutFile (Join-Path $PayloadRoot "chains\example-workflow.nuon") -UseBasicParsing
            }

            $configContent = @'
{
    default_headers: {
        "Content-Type": "application/json"
        "Accept": "application/json"
    }
    timeout_seconds: 30
    history_retention_days: 30
    editor: "code"
    colors: {
        success: "green"
        error: "red"
        warning: "yellow"
        info: "blue"
    }
}
'@
            $secretsContent = @'
{
    tokens: {}
    saml_tokens: {}
    oauth: {}
    api_keys: {}
    basic_auth: {}
}
'@
            Write-NurlUtf8 (Join-Path $PayloadRoot "config.nuon") $configContent
            Write-NurlUtf8 (Join-Path $PayloadRoot "variables.nuon") "{}"
            Write-NurlUtf8 (Join-Path $PayloadRoot "secrets.nuon") $secretsContent

            Write-Host "[2/4] Validating staged payloads..."
            $parseProbe = Invoke-NurlCapture -FilePath $nuPath.Source -Arguments @("--no-config-file", (Join-Path $PayloadRoot "api.nu"))
            if ($parseProbe.ExitCode -ne 0) {
                throw "Staged Nurl payloads failed Nushell validation; the existing installation was not changed."
            }
            $configEdit = New-NurlInstallConfig $ConfigPath

            Write-Host "[3/4] Promoting validated payloads..."
            $promotionStarted = $true
            if (-not $IsUpdate) {
                [System.IO.Directory]::Move($PayloadRoot, $NurlHome)
                $freshPromoted = $true
            } else {
                Ensure-TrackedDirectory $NurlHome
                Ensure-TrackedDirectory (Join-Path $NurlHome "nu_modules")
                Promote-NurlFile (Join-Path $PayloadRoot "api.nu") (Join-Path $NurlHome "api.nu") "api.nu"
                foreach ($module in $Modules) {
                    Promote-NurlFile (Join-Path $PayloadRoot "nu_modules\$module") (Join-Path $NurlHome "nu_modules\$module") "nu_modules\$module"
                }
                Ensure-TrackedDirectory (Join-Path $NurlHome "collections")
                Ensure-TrackedDirectory (Join-Path $NurlHome "chains")
                Ensure-TrackedDirectory (Join-Path $NurlHome "history")
                Promote-NurlFileIfAbsent (Join-Path $PayloadRoot "config.nuon") (Join-Path $NurlHome "config.nuon") "config.nuon"
                Promote-NurlFileIfAbsent (Join-Path $PayloadRoot "variables.nuon") (Join-Path $NurlHome "variables.nuon") "variables.nuon"
                Promote-NurlFileIfAbsent (Join-Path $PayloadRoot "secrets.nuon") (Join-Path $NurlHome "secrets.nuon") "secrets.nuon"
                $stagedCollection = Join-Path $PayloadRoot "collections\jsonplaceholder"
                $installedCollection = Join-Path $NurlHome "collections\jsonplaceholder"
                if ((Test-Path -LiteralPath $stagedCollection) -and $null -eq (Get-Item -LiteralPath $installedCollection -Force -ErrorAction SilentlyContinue)) {
                    [System.IO.Directory]::Move($stagedCollection, $installedCollection)
                    $rollbackRecords.Add([pscustomobject]@{ Destination = $installedCollection; Backup = $null; Created = $true })
                }
                $stagedChain = Join-Path $PayloadRoot "chains\example-workflow.nuon"
                if (Test-Path -LiteralPath $stagedChain) {
                    Promote-NurlFileIfAbsent $stagedChain (Join-Path $NurlHome "chains\example-workflow.nuon") "chains\example-workflow.nuon"
                }
            }

            Write-Host "[4/4] Configuring Nushell..."
            if ($configEdit.Changed) {
                Ensure-TrackedDirectory $NushellConfigDir
                $configTemp = Join-Path $NushellConfigDir (".config.nu.nurl." + [guid]::NewGuid().ToString("N"))
                [System.IO.File]::WriteAllBytes($configTemp, $configEdit.Bytes)
                Promote-NurlFile $configTemp $ConfigPath "nushell-config.nu"
                Write-Host "  Added the owned Nurl block to $ConfigPath"
            } else {
                Write-Host "  Nushell config already contains the owned Nurl block"
            }

            $committed = $true
            Remove-Item -LiteralPath $RollbackRoot -Recurse -Force
        } finally {
            if ($promotionStarted -and -not $committed) {
                try {
                    Undo-NurlPromotion
                } catch {
                    $rollbackState.Failed = $true
                    [Console]::Error.WriteLine("Warning: rollback encountered an unexpected failure: $($_.Exception.Message)")
                }
            }
            if ($rollbackState.Failed) {
                [Console]::Error.WriteLine("Error: rollback was incomplete; recovery files remain at '$RollbackRoot'.")
            } elseif (Test-Path -LiteralPath $StageRoot) {
                try {
                    Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction Stop
                } catch {
                    [Console]::Error.WriteLine("Warning: temporary staging remains at '$StageRoot': $($_.Exception.Message)")
                }
            }
        }

        Write-Host ""
        if ($IsUpdate) {
            Write-Host "Nurl updated successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Your collections, chains, history, secrets, variables, and NUON config were preserved."
        } else {
            Write-Host "Nurl installed successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Included the jsonplaceholder collection and example-workflow chain."
        }
        Write-Host ""
        Write-Host "Restart your terminal or run:"
        Write-Host "  source ~/.nurl/api.nu" -ForegroundColor Blue
    }

    Invoke-NurlInstall
    } finally {
        if ($hasOutputRendering) {
            $PSStyle.OutputRendering = $previousOutputRendering
        }
    }
}
