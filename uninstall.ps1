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
    if ($null -ne $PSStyle) {
        $PSStyle.OutputRendering = "PlainText"
    }

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
        $text = if ($bytes.Length -eq $offset) { "" } else { $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
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
        param([Parameter(Mandatory)][string]$Line)
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
            return [pscustomobject]@{ Changed = $false; Bytes = $file.Bytes }
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
        foreach ($configPath in $configPaths) {
            $configItem = Get-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $configItem -and ($configItem.PSIsContainer -or (($configItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
                throw "Refusing to replace a non-file Nushell config: $configPath"
            }
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $edit = New-NurlUninstallConfig $configPath
                if ($edit.Changed) {
                    $configEdits.Add([pscustomobject]@{ Path = $configPath; Bytes = $edit.Bytes })
                }
            }
        }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $BackupDir = Join-Path $env:USERPROFILE (".nurl-backup-$stamp-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        $backupComplete = $false
        try {
            Write-Host "[1/3] Creating a complete backup..."
            [void][System.IO.Directory]::CreateDirectory($BackupDir)
            Get-ChildItem -LiteralPath $NurlHome -Force | Copy-Item -Destination $BackupDir -Recurse -Force
            $sourceManifest = @(Get-NurlManifest $NurlHome)
            $backupManifest = @(Get-NurlManifest $BackupDir)
            if ([string]::Join("`n", $sourceManifest) -cne [string]::Join("`n", $backupManifest)) {
                throw "Backup verification failed; Nurl was not removed."
            }
            $backupComplete = $true

            Write-Host "[2/3] Removing $NurlHome..."
            Remove-Item -LiteralPath $NurlHome -Recurse -Force
            if (Test-Path -LiteralPath $NurlHome) {
                throw "Nurl could not be completely removed. The verified backup remains at $BackupDir."
            }

            Write-Host "[3/3] Cleaning owned Nushell config entries..."
            foreach ($edit in $configEdits) {
                $configDir = Split-Path -Parent $edit.Path
                $temp = Join-Path $configDir (".config.nu.nurl." + [guid]::NewGuid().ToString("N"))
                [System.IO.File]::WriteAllBytes($temp, $edit.Bytes)
                Move-Item -LiteralPath $temp -Destination $edit.Path -Force
            }
        } catch {
            if (-not $backupComplete -and (Test-Path -LiteralPath $BackupDir)) {
                Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }

        Write-Host ""
        Write-Host "Nurl uninstalled" -ForegroundColor Green
        Write-Host ""
        Write-Host "A complete, byte-verified backup was copied to:"
        Write-Host "  $BackupDir" -ForegroundColor Blue
        Write-Host "The backup includes all files that were present under $NurlHome,"
        Write-Host "including collections, chains, history, and NUON configuration."
    }

    Invoke-NurlUninstall -AssumeYes:$ExplicitYes
} ([bool]$Yes)
