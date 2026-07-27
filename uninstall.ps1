# Nurl Uninstallation Script for Windows
# Usage: $env:NURL_ASSUME_YES=1; irm https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.ps1 | iex

[CmdletBinding()]
param(
    [Alias("y")]
    [switch]$Yes
)

& {
    param([bool]$ExplicitYes)
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
            $text = if ($bytes.Length -eq $offset) { "" } else { $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
        } catch {
            throw "Nushell config contains invalid or unsupported text encoding: $Path"
        }
        [pscustomobject]@{ Text = $text; Encoding = $encoding; Preamble = $preamble; Bytes = $bytes }
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
            $records.Add([pscustomobject]@{ Body = $match.Groups[1].Value; Eol = $match.Groups[2].Value })
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

    function New-NurlUninstallConfig {
        param([Parameter(Mandatory)][string]$Path)

        $file = Get-NurlTextFile $Path
        $records = @(Get-NurlLineRecords $file.Text)
        $endedWithNewline = $file.Text.EndsWith("`n") -or $file.Text.EndsWith("`r")
        $newline = [Environment]::NewLine
        foreach ($record in $records) {
            if ($record.Eol.Length -gt 0) {
                $newline = $record.Eol
                break
            }
        }

        $output = [System.Collections.Generic.List[object]]::new()
        $inside = $false
        $removed = $false
        foreach ($record in $records) {
            $trimmed = $record.Body.Trim()
            if ($trimmed -ceq "# >>> nurl >>>") {
                if ($inside) {
                    throw "Nushell config contains nested Nurl sentinel blocks: $Path"
                }
                $inside = $true
                $removed = $true
                continue
            }
            if ($trimmed -ceq "# <<< nurl <<<") {
                if (-not $inside) {
                    throw "Nushell config contains an unmatched Nurl sentinel: $Path"
                }
                $inside = $false
                continue
            }
            if ($inside) {
                continue
            }
            if (Test-NurlLegacySource $record.Body) {
                if ($output.Count -gt 0 -and $output[$output.Count - 1].Body.Trim() -ceq "# Nurl - Terminal API Client") {
                    $output.RemoveAt($output.Count - 1)
                }
                $removed = $true
                continue
            }
            $output.Add([pscustomobject]@{ Body = $record.Body; Eol = $record.Eol })
        }
        if ($inside) {
            throw "Nushell config contains an unterminated Nurl sentinel block: $Path"
        }
        if (-not $removed) {
            return [pscustomobject]@{
                Changed = $false
                Bytes = $file.Bytes
                OriginalBytes = $file.Bytes
            }
        }

        if ($output.Count -gt 0) {
            if ($endedWithNewline) {
                if ($output[$output.Count - 1].Eol.Length -eq 0) {
                    $output[$output.Count - 1].Eol = $newline
                }
            } else {
                $output[$output.Count - 1].Eol = ""
            }
        }
        $builder = [System.Text.StringBuilder]::new()
        foreach ($record in $output) {
            [void]$builder.Append($record.Body)
            [void]$builder.Append($record.Eol)
        }
        [pscustomobject]@{
            Changed = $true
            Bytes = ConvertTo-NurlBytes $builder.ToString() $file
            OriginalBytes = $file.Bytes
        }
    }

    function Get-NurlManifest {
        param([Parameter(Mandatory)][string]$Root)

        $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@("\", "/"))
        @(
            Get-ChildItem -LiteralPath $rootPath -Force -Recurse |
                ForEach-Object {
                    $relative = $_.FullName.Substring($rootPath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
                    if ($_.PSIsContainer) {
                        "D|$relative"
                    } else {
                        $stream = [System.IO.File]::OpenRead($_.FullName)
                        try {
                            $sha256 = [System.Security.Cryptography.SHA256]::Create()
                            try {
                                $hash = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "")
                            } finally {
                                $sha256.Dispose()
                            }
                        } finally {
                            $stream.Dispose()
                        }
                        "F|$relative|$($_.Length)|$hash"
                    }
                } |
                Sort-Object
        )
    }

    function Assert-NurlNoReparsePoints {
        param([Parameter(Mandatory)][string]$Root)

        $pending = [System.Collections.Generic.Queue[string]]::new()
        $pending.Enqueue($Root)
        while ($pending.Count -gt 0) {
            $directory = $pending.Dequeue()
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Cannot create a verifiable backup while Nurl contains a reparse point: $($item.FullName)"
                }
                if ($item.PSIsContainer) {
                    $pending.Enqueue($item.FullName)
                }
            }
        }
    }

    function Test-NurlPathContained {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Candidate
        )
        $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@("\", "/"))
        $candidatePath = [System.IO.Path]::GetFullPath($Candidate).TrimEnd([char[]]@("\", "/"))
        $candidatePath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $candidatePath.StartsWith($rootPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
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

    function Invoke-NurlUninstall {
        param([bool]$AssumeYes)

        $NurlHome = Join-Path $env:USERPROFILE ".nurl"
        $legacyConfigDir = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            Join-Path $env:APPDATA "nushell"
        } else {
            Join-Path $env:USERPROFILE "AppData\Roaming\nushell"
        }

        Write-Host "Uninstalling Nurl" -ForegroundColor Blue
        Write-Host ""
        $nurlItem = Get-Item -LiteralPath $NurlHome -Force -ErrorAction SilentlyContinue
        if ($null -ne $nurlItem -and (($nurlItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to uninstall through a reparse-point Nurl root: $NurlHome"
        }
        if (-not (Test-Path -LiteralPath $NurlHome -PathType Container)) {
            Write-Host "Nurl is not installed at $NurlHome" -ForegroundColor Yellow
            return
        }

        if (-not $AssumeYes -and $env:NURL_ASSUME_YES -ne "1") {
            Write-Host "This will remove Nurl after creating and verifying a complete backup." -ForegroundColor Yellow
            Write-Host ""
            try {
                $confirmation = Read-Host "Continue? [y/N]"
            } catch {
                throw "Confirmation requires an interactive host. Re-run with -Yes/-y or set NURL_ASSUME_YES=1."
            }
            if ($confirmation -notmatch "^(?i:y|yes)$") {
                Write-Host "Cancelled"
                return
            }
        }
        Assert-NurlNoReparsePoints $NurlHome

        $resolvedConfigDir = $null
        $nuPath = Get-Command nu -ErrorAction SilentlyContinue
        if ($nuPath) {
            $configProbe = Invoke-NurlCapture -FilePath $nuPath.Source -Arguments @("--no-config-file", "-c", '$nu.default-config-dir')
            if ($configProbe.ExitCode -eq 0 -and $configProbe.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$configProbe.Output[0])) {
                $resolvedConfigDir = ([string]$configProbe.Output[0]).Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($resolvedConfigDir)) {
            if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
                $resolvedConfigDir = Join-Path $env:XDG_CONFIG_HOME "nushell"
            } else {
                $resolvedConfigDir = $legacyConfigDir
            }
        }

        $configPaths = [System.Collections.Generic.List[string]]::new()
        $configPaths.Add((Join-Path $resolvedConfigDir "config.nu"))
        $legacyConfigPath = Join-Path $legacyConfigDir "config.nu"
        if (-not $legacyConfigPath.Equals($configPaths[0], [System.StringComparison]::OrdinalIgnoreCase)) {
            $configPaths.Add($legacyConfigPath)
        }
        $configEdits = [System.Collections.Generic.List[object]]::new()
        $configTemps = [System.Collections.Generic.List[string]]::new()
        $configTempRecords = [System.Collections.Generic.List[object]]::new()
        $configReplacements = [System.Collections.Generic.List[object]]::new()
        foreach ($configPath in $configPaths) {
            if (Test-NurlPathContained $NurlHome $configPath) {
                throw "Nushell config must not resolve inside $NurlHome."
            }
            $configItem = Get-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $configItem -and ($configItem.PSIsContainer -or (($configItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
                throw "Refusing to replace a non-file Nushell config: $configPath"
            }
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $edit = New-NurlUninstallConfig $configPath
                if ($edit.Changed) {
                    if ($configItem.IsReadOnly) {
                        throw "Nushell config contains Nurl entries but is read-only; Nurl was not moved. Config: $configPath"
                    }
                    $configEdits.Add([pscustomobject]@{
                        Path = $configPath
                        Bytes = $edit.Bytes
                        OriginalBytes = $edit.OriginalBytes
                    })
                }
            }
        }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $BackupDir = Join-Path $env:USERPROFILE (".nurl-backup-$stamp-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        $backupComplete = $false
        $nurlDetached = $false
        try {
            foreach ($edit in $configEdits) {
                $configDir = Split-Path -Parent $edit.Path
                $tempDir = Join-Path $configDir (".config.nu.nurl." + [guid]::NewGuid().ToString("N"))
                [void][System.IO.Directory]::CreateDirectory($tempDir)
                $temp = Join-Path $tempDir "candidate"
                $tempRecord = [pscustomobject]@{ Dir = $tempDir; Candidate = $temp; Expected = $edit.Bytes; Retired = $false }
                $configTempRecords.Add($tempRecord)
                $configTemps.Add($temp)
                [System.IO.File]::WriteAllBytes($temp, $edit.Bytes)
                $edit | Add-Member -NotePropertyName Temp -NotePropertyValue $temp
            }
            $sourceManifest = @(Get-NurlManifest $NurlHome)
            Write-Host "[1/3] Atomically creating a complete backup..."
            Move-Item -LiteralPath $NurlHome -Destination $BackupDir
            $nurlDetached = $true
            $backupManifest = @(Get-NurlManifest $BackupDir)
            if ([string]::Join("`n", $sourceManifest) -cne [string]::Join("`n", $backupManifest)) {
                if (-not (Test-Path -LiteralPath $NurlHome)) {
                    Move-Item -LiteralPath $BackupDir -Destination $NurlHome
                    $nurlDetached = $false
                }
                throw "Backup verification failed; Nurl data was not deleted."
            }
            $backupComplete = $true

            if (Test-Path -LiteralPath $NurlHome) {
                throw "New Nurl data appeared during uninstall. It was left intact; the verified backup remains at $BackupDir."
            }
            Write-Host "[2/3] Nurl installation moved to the verified backup."

            Write-Host "[3/3] Cleaning owned Nushell config entries..."
            foreach ($edit in $configEdits) {
                if (-not (Test-Path -LiteralPath $edit.Path -PathType Leaf)) {
                    throw "Nushell config changed during uninstall. The Nurl backup remains at $BackupDir and config was not overwritten."
                }
                $currentConfigBytes = [System.IO.File]::ReadAllBytes($edit.Path)
                if ([Convert]::ToBase64String($currentConfigBytes) -cne [Convert]::ToBase64String([byte[]]$edit.OriginalBytes)) {
                    throw "Nushell config changed during uninstall. The Nurl backup remains at $BackupDir and config was not overwritten."
                }
                $replaceBackup = Join-Path (Split-Path -Parent $edit.Path) (".config.nu.nurl.rollback." + [guid]::NewGuid().ToString("N"))
                $configReplacements.Add([pscustomobject]@{
                    Path = $edit.Path
                    Backup = $replaceBackup
                    CandidateBytes = $edit.Bytes
                })
                [System.IO.File]::Replace($edit.Temp, $edit.Path, $replaceBackup)
                [void]$configTemps.Remove($edit.Temp)
                $tempRecord = $configTempRecords | Where-Object Candidate -eq $edit.Temp | Select-Object -First 1
                if ($null -ne $tempRecord) {
                    try {
                        [System.IO.Directory]::Delete($tempRecord.Dir, $false)
                    } catch {
                        [Console]::Error.WriteLine("Warning: consumed temp directory was preserved: $($tempRecord.Dir)")
                    }
                    $tempRecord.Retired = $true
                }
                $displacedBytes = [System.IO.File]::ReadAllBytes($replaceBackup)
                if ([Convert]::ToBase64String($displacedBytes) -cne [Convert]::ToBase64String([byte[]]$edit.OriginalBytes)) {
                    $candidateRecovery = $replaceBackup + ".candidate"
                    try {
                        [System.IO.File]::Replace($replaceBackup, $edit.Path, $candidateRecovery)
                    } catch {
                        throw "Nushell config changed during uninstall and automatic restoration failed. Recovery file: $replaceBackup"
                    }
                    $replacedBytes = [System.IO.File]::ReadAllBytes($candidateRecovery)
                    if ([Convert]::ToBase64String($replacedBytes) -ceq [Convert]::ToBase64String([byte[]]$edit.Bytes)) {
                        Remove-Item -LiteralPath $candidateRecovery -Force -ErrorAction SilentlyContinue
                    } else {
                        throw "Nushell config changed again during restoration. The latest edit remains at $candidateRecovery"
                    }
                    throw "Nushell config changed during uninstall; the concurrent edit was restored. The Nurl backup remains at $BackupDir."
                }
            }
            foreach ($replacement in $configReplacements) {
                Remove-Item -LiteralPath $replacement.Backup -Force -ErrorAction SilentlyContinue
            }
            $configReplacements.Clear()
        } catch {
            for ($index = $configReplacements.Count - 1; $index -ge 0; $index--) {
                $replacement = $configReplacements[$index]
                if (Test-Path -LiteralPath $replacement.Backup) {
                    $canRestore = $false
                    if (Test-Path -LiteralPath $replacement.Path -PathType Leaf) {
                        $currentBytes = [System.IO.File]::ReadAllBytes($replacement.Path)
                        $canRestore = [Convert]::ToBase64String($currentBytes) -ceq
                            [Convert]::ToBase64String([byte[]]$replacement.CandidateBytes)
                    }
                    if ($canRestore) {
                        $candidateRecovery = $replacement.Backup + ".candidate"
                        try {
                            [System.IO.File]::Replace($replacement.Backup, $replacement.Path, $candidateRecovery)
                            $replacedBytes = [System.IO.File]::ReadAllBytes($candidateRecovery)
                            if ([Convert]::ToBase64String($replacedBytes) -ceq
                                [Convert]::ToBase64String([byte[]]$replacement.CandidateBytes)) {
                                Remove-Item -LiteralPath $candidateRecovery -Force -ErrorAction SilentlyContinue
                            } else {
                                [Console]::Error.WriteLine("Warning: a newer config edit remains at '$candidateRecovery'.")
                            }
                        } catch {
                            [Console]::Error.WriteLine("Warning: config recovery remains at '$($replacement.Backup)': $($_.Exception.Message)")
                        }
                    } else {
                        [Console]::Error.WriteLine("Warning: config changed again; recovery remains at '$($replacement.Backup)'.")
                    }
                }
            }
            if (-not $backupComplete -and $nurlDetached -and
                (Test-Path -LiteralPath $BackupDir) -and
                -not (Test-Path -LiteralPath $NurlHome)) {
                try {
                    Move-Item -LiteralPath $BackupDir -Destination $NurlHome -ErrorAction Stop
                    $nurlDetached = $false
                } catch {
                    [Console]::Error.WriteLine("Warning: Nurl data remains at '$BackupDir': $($_.Exception.Message)")
                }
            }
            throw
        } finally {
            foreach ($tempRecord in $configTempRecords) {
                if (-not $tempRecord.Retired -and (Test-Path -LiteralPath $tempRecord.Dir -PathType Container)) {
                    try {
                        if (Test-Path -LiteralPath $tempRecord.Candidate -PathType Leaf) {
                            $ownedBytes = [System.IO.File]::ReadAllBytes($tempRecord.Candidate)
                            if ([Convert]::ToBase64String($ownedBytes) -ceq [Convert]::ToBase64String([byte[]]$tempRecord.Expected)) {
                                Remove-Item -LiteralPath $tempRecord.Candidate -Force -ErrorAction Stop
                            } else {
                                throw "candidate bytes changed"
                            }
                        }
                        [System.IO.Directory]::Delete($tempRecord.Dir, $false)
                    } catch {
                        [Console]::Error.WriteLine("Warning: config temporary directory remains at '$($tempRecord.Dir)': $($_.Exception.Message)")
                    }
                }
            }
        }

        Write-Host ""
        Write-Host "Nurl uninstalled" -ForegroundColor Green
        Write-Host ""
        Write-Host "A complete, byte-verified backup was moved to:"
        Write-Host "  $BackupDir" -ForegroundColor Blue
        Write-Host "The backup includes all files that were present under $NurlHome,"
        Write-Host "including collections, chains, history, and NUON configuration."
    }

    Invoke-NurlUninstall -AssumeYes:$ExplicitYes
    } finally {
        if ($hasOutputRendering) {
            $PSStyle.OutputRendering = $previousOutputRendering
        }
    }
} ([bool]$Yes)
