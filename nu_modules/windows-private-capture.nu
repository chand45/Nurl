# Windows response-header capture storage with explicit SID-only DACLs.

use command-error.nu [fail-command]

def private-capture-script [] {
    '
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$Operation = $env:NURL_CAPTURE_OPERATION
$CaptureName = $env:NURL_CAPTURE_NAME
$CaptureDirectory = $env:NURL_CAPTURE_DIRECTORY
$ExpectedBaseIdentity = $env:NURL_CAPTURE_BASE_ID
$ExpectedDirectoryIdentity = $env:NURL_CAPTURE_DIRECTORY_ID
$ExpectedFileIdentity = $env:NURL_CAPTURE_FILE_ID

$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$trustedSids = @($currentSid.Value, $systemSid.Value, $administratorsSid.Value)
$fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
$allow = [System.Security.AccessControl.AccessControlType]::Allow

function Get-PathIdentity {
    param([string]$Path, [bool]$Directory)
    $item = Get-Item -Force -LiteralPath $Path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Private capture storage must not be a reparse point"
    }
    if ($Directory -and -not $item.PSIsContainer) {
        throw "Private capture directory is not a directory"
    }
    if (-not $Directory -and $item.PSIsContainer) {
        throw "Private capture file is not a regular file"
    }
    $system = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    $fsutil = Join-Path $system "fsutil.exe"
    $identityOutput = @(& $fsutil file queryFileId $item.FullName 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query private capture file identity"
    }
    $matches = [regex]::Matches(($identityOutput -join " "), "0x[0-9A-Fa-f]+")
    if ($matches.Count -ne 1) {
        throw "Could not parse private capture file identity"
    }
    $matches[0].Value.ToLowerInvariant()
}

function New-StrictSecurity {
    param([bool]$Directory)
    $security = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $security.SetOwner($currentSid)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($sid in @($currentSid, $systemSid, $administratorsSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            $fullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            $allow)
        [void]$security.AddAccessRule($rule)
    }
    $security
}

function Set-StrictSecurity {
    param([string]$Path, [bool]$Directory)
    Set-Acl -LiteralPath $Path -AclObject (New-StrictSecurity $Directory)
}

function Assert-StrictSecurity {
    param([string]$Path, [bool]$Directory)
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $currentSid.Value -or -not $acl.AreAccessRulesProtected) {
        throw "Private capture owner or DACL protection is invalid"
    }
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 3) {
        throw "Private capture DACL contains unexpected entries"
    }
    $expectedInheritance = if ($Directory) { 3 } else { 0 }
    foreach ($sid in $trustedSids) {
        $matches = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
        if ($matches.Count -ne 1) {
            throw "Private capture DACL is missing a trusted identity"
        }
        $rule = $matches[0]
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne $allow -or
            [int]$rule.FileSystemRights -ne [int]$fullControl -or
            [int]$rule.InheritanceFlags -ne $expectedInheritance -or
            [int]$rule.PropagationFlags -ne 0) {
            throw "Private capture DACL entry is not canonical"
        }
    }
    foreach ($rule in $rules) {
        if ($rule.IdentityReference.Value -notin $trustedSids) {
            throw "Private capture DACL grants an untrusted identity"
        }
    }
}

function Assert-SafeParent {
    param([string]$Path)
    [void](Get-PathIdentity $Path $true)
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trustedSids) {
        throw "Private capture base parent has an untrusted owner"
    }
    $dangerous = [int](
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        if ($rule.AccessControlType -eq $allow -and
            $rule.IdentityReference.Value -notin $trustedSids -and
            (([int]$rule.FileSystemRights -band $dangerous) -ne 0)) {
            throw "Private capture base parent grants unsafe peer access"
        }
    }
}

function Get-BasePath {
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($local)) {
        throw "Local application data is unavailable"
    }
    $local = [System.IO.Path]::GetFullPath($local)
    Assert-SafeParent $local
    Join-Path $local "NurlPrivateHttp"
}

function Initialize-Base {
    $base = Get-BasePath
    if (Test-Path -LiteralPath $base) {
        [void](Get-PathIdentity $base $true)
    } else {
        [void][System.IO.Directory]::CreateDirectory($base)
    }
    Set-StrictSecurity $base $true
    Assert-StrictSecurity $base $true
    [pscustomobject]@{ Path = $base; Identity = Get-PathIdentity $base $true }
}

function Get-VerifiedBase {
    param([string]$ExpectedIdentity)
    $base = Get-BasePath
    $identity = Get-PathIdentity $base $true
    if ($identity -ne $ExpectedIdentity) {
        throw "Private capture base identity changed"
    }
    Assert-StrictSecurity $base $true
    [pscustomobject]@{ Path = $base; Identity = $identity }
}

function Assert-CapturePath {
    param([string]$Base, [string]$Capture)
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd("\")
    $captureFull = [System.IO.Path]::GetFullPath($Capture)
    if ([System.IO.Path]::GetDirectoryName($captureFull) -ne $baseFull -or
        -not [System.IO.Path]::GetFileName($captureFull).StartsWith("nurl-response-headers-")) {
        throw "Private capture path is outside the owned base"
    }
}

function Get-VerifiedCapture {
    param([string]$Capture, [string]$DirectoryIdentity, [string]$FileIdentity, [bool]$VerifySecurity = $true)
    $file = Join-Path $Capture "headers"
    $actualDirectoryIdentity = Get-PathIdentity $Capture $true
    $actualFileIdentity = Get-PathIdentity $file $false
    if ($actualDirectoryIdentity -ne $DirectoryIdentity -or $actualFileIdentity -ne $FileIdentity) {
        throw "Private capture identity changed"
    }
    if ($VerifySecurity) {
        Assert-StrictSecurity $Capture $true
        Assert-StrictSecurity $file $false
    }
    [pscustomobject]@{ File = $file }
}

if ($Operation -eq "create") {
    $base = Initialize-Base
    $CaptureDirectory = Join-Path $base.Path $CaptureName
    Assert-CapturePath $base.Path $CaptureDirectory
    if (Test-Path -LiteralPath $CaptureDirectory) {
        throw "Private capture path already exists"
    }
    [void][System.IO.Directory]::CreateDirectory($CaptureDirectory)
    Set-StrictSecurity $CaptureDirectory $true
    Assert-StrictSecurity $CaptureDirectory $true
    $file = Join-Path $CaptureDirectory "headers"
    $stream = New-Object System.IO.FileStream($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $stream.Dispose()
    Set-StrictSecurity $file $false
    Assert-StrictSecurity $file $false
    [pscustomobject]@{
        base = $base.Path
        base_identity = $base.Identity
        dir = $CaptureDirectory
        dir_identity = Get-PathIdentity $CaptureDirectory $true
        file = $file
        file_identity = Get-PathIdentity $file $false
    } | ConvertTo-Json -Compress
    exit 0
}

$verifiedBase = Get-VerifiedBase $ExpectedBaseIdentity
Assert-CapturePath $verifiedBase.Path $CaptureDirectory
if ($Operation -eq "cleanup" -and -not (Test-Path -LiteralPath $CaptureDirectory)) {
    [pscustomobject]@{ header_base64 = "" } | ConvertTo-Json -Compress
    exit 0
}
$capture = $null
try {
    $capture = Get-VerifiedCapture $CaptureDirectory $ExpectedDirectoryIdentity $ExpectedFileIdentity $true
} catch {
    try {
        $capture = Get-VerifiedCapture $CaptureDirectory $ExpectedDirectoryIdentity $ExpectedFileIdentity $false
        Set-StrictSecurity $capture.File $false
        Set-StrictSecurity $CaptureDirectory $true
        [System.IO.File]::Delete($capture.File)
        [System.IO.Directory]::Delete($CaptureDirectory, $false)
    } catch {
        # Identity changes are deliberately left untouched.
    }
    throw
}

$headerBase64 = if ($Operation -eq "finish") {
    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($capture.File))
} elseif ($Operation -eq "cleanup") {
    ""
} else {
    throw "Unknown private capture operation"
}
[System.IO.File]::Delete($capture.File)
[System.IO.Directory]::Delete($CaptureDirectory, $false)
[pscustomobject]@{ header_base64 = $headerBase64 } | ConvertTo-Json -Compress
'
}

export def run-windows-private-capture [operation: string, capture: record = {}] {
    if $nu.os-info.name != "windows" {
        fail-command "Windows private response-header capture is unavailable on this platform"
    }
    let system_root = ($env.SystemRoot? | default "")
    let powershell = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "powershell.exe")
    let ps_module_path = ($system_root | path join "System32" "WindowsPowerShell" "v1.0" "Modules")
    if $system_root == "" or (not ($powershell | path exists)) {
        fail-command "Windows response-header ACL protection is unavailable"
    }
    let result = (with-env {
        NURL_CAPTURE_OPERATION: $operation
        NURL_CAPTURE_NAME: ($capture.name? | default "")
        NURL_CAPTURE_DIRECTORY: ($capture.dir? | default "")
        NURL_CAPTURE_BASE_ID: ($capture.base_identity? | default "")
        NURL_CAPTURE_DIRECTORY_ID: ($capture.dir_identity? | default "")
        NURL_CAPTURE_FILE_ID: ($capture.file_identity? | default "")
        PSModulePath: $ps_module_path
    } {
        ^$powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (private-capture-script) | complete
    })
    if $result.exit_code != 0 {
        fail-command "Could not establish or verify private Windows response-header capture storage"
    }
    try {
        $result.stdout | from json
    } catch {
        fail-command "Could not verify the Windows response-header ACL result"
    }
}
