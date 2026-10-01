# DevKit.Engine.psm1
# PowerShell Engine for agent-devkit

function Get-DevKitSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $null
    }

    $hash = Get-FileHash -Path $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function Resolve-DevKitComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profileSkillDir = Join-Path $DevKitRoot "profiles\$ProfileName\skills\$SkillName"
    $coreSkillDir = Join-Path $DevKitRoot "core\skills\$SkillName"

    $sourceType = $null
    $resolvedDir = $null

    if (Test-Path -Path $profileSkillDir -PathType Container) {
        $sourceType = "profile:$ProfileName"
        $resolvedDir = $profileSkillDir
    }
    elseif (Test-Path -Path $coreSkillDir -PathType Container) {
        $sourceType = "core"
        $resolvedDir = $coreSkillDir
    }
    else {
        return $null
    }

    $files = @{}
    $allFiles = Get-ChildItem -Path $resolvedDir -Recurse -File
    $resolvedDirPrefix = $resolvedDir.TrimEnd('\', '/')
    foreach ($file in $allFiles) {
        $relPath = $file.FullName.Substring($resolvedDirPrefix.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = Get-DevKitSha256 -Path $file.FullName
        $files[$relPath] = @{
            sha256 = $hash
            length = $file.Length
        }
    }

    return @{
        skillName   = $SkillName
        source      = $sourceType
        sourceDir   = $resolvedDir
        files       = $files
    }
}

function Resolve-DevKitHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HookName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profileHookPath = Join-Path $DevKitRoot "profiles\$ProfileName\hooks\$HookName"
    $coreHookPath = Join-Path $DevKitRoot "core\hooks\$HookName"

    $sourceType = $null
    $resolvedPath = $null

    if (Test-Path -Path $profileHookPath -PathType Leaf) {
        $sourceType = "profile:$ProfileName"
        $resolvedPath = $profileHookPath
    }
    elseif (Test-Path -Path $coreHookPath -PathType Leaf) {
        $sourceType = "core"
        $resolvedPath = $coreHookPath
    }
    else {
        return $null
    }

    $hash = Get-DevKitSha256 -Path $resolvedPath
    return @{
        hookName     = $HookName
        source       = $sourceType
        sourcePath   = $resolvedPath
        sha256       = $hash
    }
}

function Get-DevKitManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir
    )

    $jsonPath = Join-Path $ProjectDir "agent-devkit.json"
    if (Test-Path -Path $jsonPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
        return $content | ConvertFrom-Json
    }
    return $null
}

function Get-DevKitLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir
    )

    $lockPath = Join-Path $ProjectDir "agent-devkit.lock"
    if (Test-Path -Path $lockPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8)
        return $content | ConvertFrom-Json
    }
    return $null
}

function Save-DevKitLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $true)]
        [psobject]$LockObject
    )

    $lockPath = Join-Path $ProjectDir "agent-devkit.lock"
    $json = $LockObject | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($lockPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Test-DevKitProjectState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $true)]
        [psobject]$Manifest,

        [Parameter(Mandatory = $false)]
        [psobject]$Lock,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $results = [System.Collections.Generic.List[psobject]]::new()
    $profile = $Manifest.profile

    $skillTargets = [System.Collections.Generic.List[string]]::new()
    $hookTargets = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $Manifest.targets) {
        if ($Manifest.targets.skills) {
            foreach ($t in $Manifest.targets.skills) { $skillTargets.Add($t) }
        }
        if ($Manifest.targets.hooks) {
            foreach ($t in $Manifest.targets.hooks) { $hookTargets.Add($t) }
        }
        if ($Manifest.targets -is [System.Array]) {
            foreach ($t in $Manifest.targets) {
                if ($t -like "*hook*") {
                    $hookTargets.Add($t)
                } else {
                    $skillTargets.Add($t)
                }
            }
        }
    }

    if ($skillTargets.Count -eq 0) {
        $skillTargets.Add(".agents/skills")
        $skillTargets.Add(".claude/skills")
    }
    if ($hookTargets.Count -eq 0) {
        $hookTargets.Add(".claude/hooks")
    }

    # Extract requested skills
    $requestedSkills = [System.Collections.Generic.List[string]]::new()
    if ($Manifest.skills) {
        foreach ($s in $Manifest.skills) {
            if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
        }
    }
    if ($Manifest.components) {
        if ($Manifest.components.core) {
            foreach ($s in $Manifest.components.core) {
                if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
            }
        }
        if ($Manifest.components.profile) {
            foreach ($s in $Manifest.components.profile) {
                if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
            }
        }
        if ($Manifest.components.skills) {
            foreach ($s in $Manifest.components.skills) {
                if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
            }
        }
    }

    # Extract requested hooks
    $requestedHooks = [System.Collections.Generic.List[string]]::new()
    if ($Manifest.hooks) {
        foreach ($h in $Manifest.hooks) {
            if (-not $requestedHooks.Contains($h)) { $requestedHooks.Add($h) }
        }
    }
    if ($Manifest.components) {
        if ($Manifest.components.hooks) {
            foreach ($h in $Manifest.components.hooks) {
                if (-not $requestedHooks.Contains($h)) { $requestedHooks.Add($h) }
            }
        }
    }

    # 1. Process Skills
    foreach ($skillName in $requestedSkills) {
        $resolved = Resolve-DevKitComponent -SkillName $skillName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type        = "skill"
                Component   = $skillName
                Skill       = $skillName
                File        = "*"
                Target      = "*"
                TargetPath  = $null
                Source      = $null
                SourcePath  = $null
                Status      = "unresolved"
                SourceHash  = $null
                LockHash    = $null
                TargetHash  = $null
                Description = "Skill not found in DevKit core or profile $profile"
            })
            continue
        }

        # Check in lock
        $lockSkill = $null
        if ($null -ne $Lock -and $null -ne $Lock.skills) {
            $lockSkill = $Lock.skills.$skillName
        }

        foreach ($targetBase in $skillTargets) {
            $targetSkillDir = Join-Path $ProjectDir (Join-Path $targetBase $skillName)

            foreach ($relFile in $resolved.files.Keys) {
                $sourceHash = $resolved.files[$relFile].sha256
                $targetFile = Join-Path $targetSkillDir $relFile.Replace('/', '\')
                $lockHash = $null

                if ($null -ne $lockSkill -and $null -ne $lockSkill.files) {
                    $lockFileEntry = $lockSkill.files.$relFile
                    if ($null -ne $lockFileEntry) {
                        $lockHash = $lockFileEntry.sha256
                    }
                }

                $targetExists = Test-Path -Path $targetFile -PathType Leaf
                $targetHash = if ($targetExists) { Get-DevKitSha256 -Path $targetFile } else { $null }

                $status = "unknown"
                $description = ""

                if (-not $targetExists) {
                    $status = "missing"
                    $description = "File does not exist in target"
                }
                elseif ($null -eq $lockHash) {
                    if ($targetHash -eq $sourceHash) {
                        $status = "synced"
                        $description = "File matches source exactly"
                    }
                    else {
                        $status = "modified"
                        $description = "Local target file differs from source (unlocked)"
                    }
                }
                else {
                    $targetMatchesLock = ($targetHash -eq $lockHash)
                    $sourceMatchesLock = ($sourceHash -eq $lockHash)

                    if ($targetMatchesLock -and $sourceMatchesLock) {
                        $status = "synced"
                        $description = "File matches lock and source exactly"
                    }
                    elseif ($targetMatchesLock -and (-not $sourceMatchesLock)) {
                        $status = "update_available"
                        $description = "Upstream source updated; target is cleanly at lock version"
                    }
                    elseif ((-not $targetMatchesLock) -and $sourceMatchesLock) {
                        $status = "modified"
                        $description = "Local target file modified; source unchanged"
                    }
                    else {
                        $status = "conflict"
                        $description = "Both local target and source differ from lock"
                    }
                }

                $targetDisplay = Join-Path $targetBase (Join-Path $skillName $relFile).Replace('\', '/')

                $results.Add([PSCustomObject]@{
                    Type        = "skill"
                    Component   = $skillName
                    Skill       = $skillName
                    File        = $relFile
                    Target      = $targetDisplay
                    TargetPath  = $targetFile
                    Source      = $resolved.source
                    SourcePath  = Join-Path $resolved.sourceDir $relFile.Replace('/', '\')
                    Status      = $status
                    SourceHash  = $sourceHash
                    LockHash    = $lockHash
                    TargetHash  = $targetHash
                    Description = $description
                })
            }
        }
    }

    # 2. Process Hooks
    foreach ($hookName in $requestedHooks) {
        $resolved = Resolve-DevKitHook -HookName $hookName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type        = "hook"
                Component   = $hookName
                Skill       = $hookName
                File        = $hookName
                Target      = "*"
                TargetPath  = $null
                Source      = $null
                SourcePath  = $null
                Status      = "unresolved"
                SourceHash  = $null
                LockHash    = $null
                TargetHash  = $null
                Description = "Hook not found in DevKit core or profile $profile"
            })
            continue
        }

        # Check in lock
        $lockHook = $null
        if ($null -ne $Lock -and $null -ne $Lock.hooks) {
            $lockHook = $Lock.hooks.$hookName
        }

        $sourceHash = $resolved.sha256
        $sourcePath = $resolved.sourcePath
        $lockHash = if ($null -ne $lockHook) { $lockHook.sha256 } else { $null }

        foreach ($targetBase in $hookTargets) {
            $targetFile = Join-Path (Join-Path $ProjectDir $targetBase) $hookName
            $targetExists = Test-Path -Path $targetFile -PathType Leaf
            $targetHash = if ($targetExists) { Get-DevKitSha256 -Path $targetFile } else { $null }

            $status = "unknown"
            $description = ""

            if (-not $targetExists) {
                $status = "missing"
                $description = "Hook does not exist in target"
            }
            elseif ($null -eq $lockHash) {
                if ($targetHash -eq $sourceHash) {
                    $status = "synced"
                    $description = "Hook matches source exactly"
                }
                else {
                    $status = "modified"
                    $description = "Local target hook differs from source (unlocked)"
                }
            }
            else {
                $targetMatchesLock = ($targetHash -eq $lockHash)
                $sourceMatchesLock = ($sourceHash -eq $lockHash)

                if ($targetMatchesLock -and $sourceMatchesLock) {
                    $status = "synced"
                    $description = "Hook matches lock and source exactly"
                }
                elseif ($targetMatchesLock -and (-not $sourceMatchesLock)) {
                    $status = "update_available"
                    $description = "Upstream hook updated; target is cleanly at lock version"
                }
                elseif ((-not $targetMatchesLock) -and $sourceMatchesLock) {
                    $status = "modified"
                    $description = "Local target hook modified; source unchanged"
                }
                else {
                    $status = "conflict"
                    $description = "Both local target and source differ from lock"
                }
            }

            $targetDisplay = Join-Path $targetBase $hookName.Replace('\', '/')

            $results.Add([PSCustomObject]@{
                Type        = "hook"
                Component   = $hookName
                Skill       = $hookName
                File        = $hookName
                Target      = $targetDisplay
                TargetPath  = $targetFile
                Source      = $resolved.source
                SourcePath  = $sourcePath
                Status      = $status
                SourceHash  = $sourceHash
                LockHash    = $lockHash
                TargetHash  = $targetHash
                Description = $description
            })
        }
    }

    return $results
}

function Invoke-DevKitSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [psobject]$Manifest = $null,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    if ($null -eq $Manifest) {
        $Manifest = Get-DevKitManifest -ProjectDir $ProjectDir
    }
    if ($null -eq $Manifest) {
        throw "Manifest agent-devkit.json not found in $ProjectDir"
    }

    $lock = Get-DevKitLock -ProjectDir $ProjectDir
    $state = Test-DevKitProjectState -ProjectDir $ProjectDir -Manifest $manifest -Lock $lock -DevKitRoot $DevKitRoot

    $syncedCount = 0
    $materializedCount = 0
    $blockedCount = 0
    $missingCount = 0

    $newLockSkills = @{}
    $newLockHooks = @{}

    foreach ($item in $state) {
        if ($item.Type -eq "hook") {
            $hookName = $item.Component
            if (-not $newLockHooks.ContainsKey($hookName)) {
                $newLockHooks[$hookName] = @{
                    source = $item.Source
                    sha256 = $item.SourceHash
                }
            }
        }
        else {
            $skillName = $item.Skill
            if (-not $newLockSkills.ContainsKey($skillName)) {
                $newLockSkills[$skillName] = @{
                    source  = $item.Source
                    version = "1.0.0"
                    files   = @{}
                }
            }

            if ($null -ne $item.File -and $item.File -ne "*") {
                $newLockSkills[$skillName].files[$item.File] = @{
                    sha256 = $item.SourceHash
                }
            }
        }

        switch ($item.Status) {
            "synced" {
                $syncedCount++
            }
            "missing" {
                $missingCount++
                if (-not $DryRun) {
                    $targetDir = [System.IO.Path]::GetDirectoryName($item.TargetPath)
                    if (-not (Test-Path -Path $targetDir)) {
                        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                    }
                    Copy-Item -Path $item.SourcePath -Destination $item.TargetPath
                    $materializedCount++
                }
            }
            "update_available" {
                if (-not $DryRun) {
                    Copy-Item -Path $item.SourcePath -Destination $item.TargetPath
                    $materializedCount++
                }
            }
            "modified" {
                $blockedCount++
                Write-Warning "Refusing to overwrite locally modified file: $($item.Target)"
            }
            "conflict" {
                $blockedCount++
                Write-Error "Conflict detected in $($item.Target). Both source and target differ from lock."
            }
            "unresolved" {
                $blockedCount++
                Write-Error "Cannot resolve component: $($item.Component)"
            }
        }
    }

    if (-not $DryRun -and $blockedCount -eq 0) {
        $newLock = [PSCustomObject]@{
            lockfileVersion = "1.0.0"
            generatedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            profile         = "$($manifest.profile)@1.0.0"
            skills          = $newLockSkills
            hooks           = $newLockHooks
        }
        Save-DevKitLock -ProjectDir $ProjectDir -LockObject $newLock
    }

    return [PSCustomObject]@{
        DryRun       = [bool]$DryRun
        TotalFiles   = $state.Count
        Synced       = $syncedCount
        Materialized = $materializedCount
        Missing      = $missingCount
        Blocked      = $blockedCount
        State        = $state
    }
}

function Invoke-DevKitVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [psobject]$Manifest = $null,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    if ($null -eq $Manifest) {
        $Manifest = Get-DevKitManifest -ProjectDir $ProjectDir
    }
    if ($null -eq $Manifest) {
        throw "Manifest agent-devkit.json not found in $ProjectDir"
    }

    $lock = Get-DevKitLock -ProjectDir $ProjectDir
    $state = Test-DevKitProjectState -ProjectDir $ProjectDir -Manifest $manifest -Lock $lock -DevKitRoot $DevKitRoot

    $discrepancies = $state | Where-Object { $_.Status -ne "synced" }

    return [PSCustomObject]@{
        Verified      = ($discrepancies.Count -eq 0)
        TotalFiles    = $state.Count
        Discrepancies = $discrepancies
        State         = $state
    }
}

Export-ModuleMember -Function `
    Get-DevKitSha256, `
    Resolve-DevKitComponent, `
    Resolve-DevKitHook, `
    Get-DevKitManifest, `
    Get-DevKitLock, `
    Save-DevKitLock, `
    Test-DevKitProjectState, `
    Invoke-DevKitSync, `
    Invoke-DevKitVerify
