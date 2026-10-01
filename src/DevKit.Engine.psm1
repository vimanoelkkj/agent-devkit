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

function Get-DevKitThirdPartyRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $registryPath = Join-Path $DevKitRoot "registry\third-party.json"
    if (Test-Path -Path $registryPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($registryPath, [System.Text.Encoding]::UTF8)
        return $content | ConvertFrom-Json
    }
    return $null
}

function Get-DevKitSkillDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillDir
    )

    $skillMd = Join-Path $SkillDir "SKILL.md"
    if (Test-Path -Path $skillMd -PathType Leaf) {
        $lines = [System.IO.File]::ReadAllLines($skillMd, [System.Text.Encoding]::UTF8)
        $inFrontmatter = $false
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq "---") {
                if ($inFrontmatter) { break }
                $inFrontmatter = $true
                continue
            }
            if ($inFrontmatter -and $trimmed -match '^description:\s*(.+)$') {
                return $matches[1].Trim('"', "'")
            }
        }
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith("#") -and $trimmed -ne "---") {
                return $trimmed
            }
        }
    }
    return ""
}

function Get-DevKitProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profilePath = Join-Path $DevKitRoot "profiles\$ProfileName\profile.json"
    if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
        throw "Profile '$ProfileName' not found at '$profilePath'."
    }

    $content = [System.IO.File]::ReadAllText($profilePath, [System.Text.Encoding]::UTF8)
    return $content | ConvertFrom-Json
}

function Get-DevKitProfileList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profilesDir = Join-Path $DevKitRoot "profiles"
    $results = [System.Collections.Generic.List[psobject]]::new()
    if (-not (Test-Path -Path $profilesDir -PathType Container)) {
        return @()
    }

    $dirs = Get-ChildItem -Path $profilesDir -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $profileFile = Join-Path $d.FullName "profile.json"
        if (Test-Path -Path $profileFile -PathType Leaf) {
            $content = [System.IO.File]::ReadAllText($profileFile, [System.Text.Encoding]::UTF8)
            $obj = $content | ConvertFrom-Json

            $skillsCount = if ($obj.skills) { $obj.skills.Count } else { 0 }
            $tpSkillsCount = if ($obj.thirdPartySkills) { $obj.thirdPartySkills.Count } else { 0 }
            $hooksCount = if ($obj.hooks) { $obj.hooks.Count } else { 0 }

            $declaredSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($obj.skills) { foreach ($s in $obj.skills) { $declaredSkills.Add($s) | Out-Null } }

            $pSkillsDir = Join-Path $d.FullName "skills"
            $undeclaredCount = 0
            if (Test-Path -Path $pSkillsDir -PathType Container) {
                $pSkillDirs = Get-ChildItem -Path $pSkillsDir -Directory -ErrorAction SilentlyContinue
                foreach ($ps in $pSkillDirs) {
                    if (-not $declaredSkills.Contains($ps.Name)) {
                        $undeclaredCount++
                    }
                }
            }

            $results.Add([PSCustomObject]@{
                Name             = $obj.name
                Version          = $obj.version
                Description      = $obj.description
                SkillsCount      = $skillsCount
                ThirdPartyCount  = $tpSkillsCount
                TotalSkillsCount = $skillsCount + $tpSkillsCount
                HooksCount       = $hooksCount
                AvailableCount   = $undeclaredCount
                Path             = $profileFile
            })
        }
    }

    return ,($results.ToArray())
}

function Get-DevKitSkillCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $skills = [System.Collections.Generic.List[psobject]]::new()

    # Pre-load profiles to know which profiles declare which skills
    $profileList = Get-DevKitProfileList -DevKitRoot $DevKitRoot
    $profileMap = @{}
    foreach ($p in $profileList) {
        $profileObj = Get-DevKitProfile -ProfileName $p.Name -DevKitRoot $DevKitRoot
        $profileMap[$p.Name] = $profileObj
    }

    # 1. Core skills (under core/skills/*)
    $coreSkillsDir = Join-Path $DevKitRoot "core\skills"
    if (Test-Path -Path $coreSkillsDir -PathType Container) {
        $coreDirs = Get-ChildItem -Path $coreSkillsDir -Directory -ErrorAction SilentlyContinue
        foreach ($cd in $coreDirs) {
            $desc = Get-DevKitSkillDescription -SkillDir $cd.FullName
            $usingProfiles = [System.Collections.Generic.List[string]]::new()
            foreach ($pName in $profileMap.Keys) {
                $pObj = $profileMap[$pName]
                if ($pObj.skills -and ($pObj.skills -contains $cd.Name)) {
                    $usingProfiles.Add($pName)
                }
            }

            $skills.Add([PSCustomObject]@{
                Name        = $cd.Name
                Category    = "core"
                Ownership   = "core"
                Source      = "core"
                Policy      = "trusted-core"
                Ref         = $null
                Subpath     = $null
                License     = "internal"
                Description = $desc
                State       = "declared"
                Profile     = $null
                Profiles    = @($usingProfiles)
                Path        = "core/skills/$($cd.Name)"
            })
        }
    }

    # 2. Profile-specific skills (under profiles/*/skills/*)
    $profilesDir = Join-Path $DevKitRoot "profiles"
    if (Test-Path -Path $profilesDir -PathType Container) {
        $pDirs = Get-ChildItem -Path $profilesDir -Directory -ErrorAction SilentlyContinue
        foreach ($pd in $pDirs) {
            $pName = $pd.Name
            $pObj = $profileMap[$pName]
            $pSkillsDir = Join-Path $pd.FullName "skills"
            if (Test-Path -Path $pSkillsDir -PathType Container) {
                $pSkillDirs = Get-ChildItem -Path $pSkillsDir -Directory -ErrorAction SilentlyContinue
                foreach ($psd in $pSkillDirs) {
                    $desc = Get-DevKitSkillDescription -SkillDir $psd.FullName
                    $isDeclared = ($null -ne $pObj -and $null -ne $pObj.skills -and ($pObj.skills -contains $psd.Name))
                    $state = if ($isDeclared) { "declared" } else { "available" }
                    $usingProfiles = if ($isDeclared) { @($pName) } else { @() }

                    $skills.Add([PSCustomObject]@{
                        Name        = $psd.Name
                        Category    = "profile-specific"
                        Ownership   = "profile-specific"
                        Source      = "profile:$pName"
                        Policy      = "profile-owned"
                        Ref         = $null
                        Subpath     = $null
                        License     = "internal"
                        Description = $desc
                        State       = $state
                        Profile     = $pName
                        Profiles    = $usingProfiles
                        Path        = "profiles/$pName/skills/$($psd.Name)"
                    })
                }
            }
        }
    }

    # 3. Third-party skills (from registry/third-party.json)
    $tpReg = Get-DevKitThirdPartyRegistry -DevKitRoot $DevKitRoot
    if ($tpReg -and $tpReg.registry) {
        foreach ($prop in $tpReg.registry.PSObject.Properties) {
            $tpName = $prop.Name
            $tpItem = $prop.Value
            $usingProfiles = [System.Collections.Generic.List[string]]::new()
            foreach ($pName in $profileMap.Keys) {
                $pObj = $profileMap[$pName]
                if ($pObj.thirdPartySkills -and ($pObj.thirdPartySkills -contains $tpName)) {
                    $usingProfiles.Add($pName)
                }
                elseif ($pObj.skills -and ($pObj.skills -contains $tpName)) {
                    $usingProfiles.Add($pName)
                }
            }

            $skills.Add([PSCustomObject]@{
                Name        = $tpName
                Category    = "third-party"
                Ownership   = "third-party"
                Source      = "third-party:github:$($tpItem.repo)@$($tpItem.ref)"
                Policy      = if ($tpItem.policy) { $tpItem.policy } else { "data-only" }
                Ref         = $tpItem.ref
                Subpath     = $tpItem.subpath
                License     = $tpItem.license
                Description = $tpItem.description
                State       = "registered"
                Profile     = $null
                Profiles    = @($usingProfiles)
                Path        = "registry/third-party.json"
            })
        }
    }

    return $skills
}

function Get-DevKitSkillInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = $null
    )

    $catalog = Get-DevKitSkillCatalog -DevKitRoot $DevKitRoot
    $matches = @($catalog | Where-Object { $_.Name -eq $SkillName })

    if ($matches.Count -eq 0) {
        return $null
    }

    if ($matches.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($ProfileName)) {
        $exact = $matches | Where-Object { $_.Profile -eq $ProfileName }
        if ($exact) { return $exact }
    }

    return $matches[0]
}

function Add-DevKitProfileSkill {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profilePath = Join-Path $DevKitRoot "profiles\$ProfileName\profile.json"
    if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
        throw "Profile '$ProfileName' does not exist at '$profilePath'."
    }

    $catalog = Get-DevKitSkillCatalog -DevKitRoot $DevKitRoot
    $skillMatches = @($catalog | Where-Object { $_.Name -eq $SkillName })

    if ($skillMatches.Count -eq 0) {
        throw "Skill '$SkillName' is not known in DevKit catalog (core, profile-specific, or third-party)."
    }

    $matchedSkill = $skillMatches[0]
    if ($skillMatches.Count -gt 1) {
        $thisProfMatch = $skillMatches | Where-Object { $_.Profile -eq $ProfileName }
        if ($thisProfMatch) {
            $matchedSkill = $thisProfMatch
        }
    }

    if ($matchedSkill.Category -eq "profile-specific" -and $matchedSkill.Profile -ne $ProfileName) {
        throw "Skill '$SkillName' is profile-specific to '$($matchedSkill.Profile)' and cannot be added to '$ProfileName'. To share it, promote it to core."
    }

    $content = [System.IO.File]::ReadAllText($profilePath, [System.Text.Encoding]::UTF8)
    $profileObj = $content | ConvertFrom-Json

    $existingSkills = [System.Collections.Generic.List[string]]::new()
    if ($profileObj.skills) {
        foreach ($s in $profileObj.skills) { $existingSkills.Add($s) }
    }

    $existingTpSkills = [System.Collections.Generic.List[string]]::new()
    if ($profileObj.thirdPartySkills) {
        foreach ($s in $profileObj.thirdPartySkills) { $existingTpSkills.Add($s) }
    }

    if ($existingSkills.Contains($SkillName) -or $existingTpSkills.Contains($SkillName)) {
        throw "Skill '$SkillName' is already declared in profile '$ProfileName'."
    }

    if ($matchedSkill.Category -eq "third-party") {
        $existingTpSkills.Add($SkillName)
    }
    else {
        $existingSkills.Add($SkillName)
    }

    $updatedProfile = [ordered]@{
        name             = $profileObj.name
        version          = $profileObj.version
        description      = $profileObj.description
        skills           = @($existingSkills)
        hooks            = if ($profileObj.hooks) { @($profileObj.hooks) } else { @() }
        thirdPartySkills = @($existingTpSkills)
    }

    $json = $updatedProfile | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($profilePath, $json + "`n", [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{
        ProfileName = $ProfileName
        SkillName   = $SkillName
        Category    = $matchedSkill.Category
        Action      = "added"
        TargetList  = if ($matchedSkill.Category -eq "third-party") { "thirdPartySkills" } else { "skills" }
        Message     = "Skill '$SkillName' added to profile '$ProfileName' ($($matchedSkill.Category))."
    }
}

function Remove-DevKitProfileSkill {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profilePath = Join-Path $DevKitRoot "profiles\$ProfileName\profile.json"
    if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
        throw "Profile '$ProfileName' does not exist at '$profilePath'."
    }

    $content = [System.IO.File]::ReadAllText($profilePath, [System.Text.Encoding]::UTF8)
    $profileObj = $content | ConvertFrom-Json

    $existingSkills = [System.Collections.Generic.List[string]]::new()
    if ($profileObj.skills) {
        foreach ($s in $profileObj.skills) { $existingSkills.Add($s) }
    }

    $existingTpSkills = [System.Collections.Generic.List[string]]::new()
    if ($profileObj.thirdPartySkills) {
        foreach ($s in $profileObj.thirdPartySkills) { $existingTpSkills.Add($s) }
    }

    $removedFrom = $null
    if ($existingSkills.Contains($SkillName)) {
        $existingSkills.Remove($SkillName) | Out-Null
        $removedFrom = "skills"
    }
    elseif ($existingTpSkills.Contains($SkillName)) {
        $existingTpSkills.Remove($SkillName) | Out-Null
        $removedFrom = "thirdPartySkills"
    }
    else {
        throw "Skill '$SkillName' is not declared in profile '$ProfileName'."
    }

    $updatedProfile = [ordered]@{
        name             = $profileObj.name
        version          = $profileObj.version
        description      = $profileObj.description
        skills           = @($existingSkills)
        hooks            = if ($profileObj.hooks) { @($profileObj.hooks) } else { @() }
        thirdPartySkills = @($existingTpSkills)
    }

    $json = $updatedProfile | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($profilePath, $json + "`n", [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{
        ProfileName = $ProfileName
        SkillName   = $SkillName
        Action      = "removed"
        RemovedFrom = $removedFrom
        Message     = "Removed '$SkillName' from profile '$ProfileName'. Consumer files and lockfile are preserved; a future explicit reconciliation/prune operation may be needed for physical cleanup."
    }
}

function Resolve-DevKitThirdParty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComponentName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $reg = Get-DevKitThirdPartyRegistry -DevKitRoot $DevKitRoot
    if ($null -eq $reg -or $null -eq $reg.registry) {
        return $null
    }

    $entry = $reg.registry.$ComponentName
    if ($null -eq $entry) {
        return $null
    }

    # Validate provider
    if ($entry.type -ne "github") {
        throw "Unsupported provider '$($entry.type)' for third-party component '$ComponentName'. Only 'github' is currently supported."
    }

    # Validate repo format: owner/repo
    if ($entry.repo -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') {
        throw "Invalid repository format '$($entry.repo)' in third-party entry '$ComponentName'."
    }

    # Validate ref
    if ([string]::IsNullOrWhiteSpace($entry.ref) -or $entry.ref -notmatch '^[a-zA-Z0-9_.-]+$') {
        throw "Invalid ref '$($entry.ref)' in third-party entry '$ComponentName'."
    }

    # Validate subpath
    if ([string]::IsNullOrWhiteSpace($entry.subpath)) {
        throw "Missing subpath in third-party entry '$ComponentName'."
    }
    if ($entry.subpath -match '^[\\/]' -or $entry.subpath -match '^[a-zA-Z]:' -or $entry.subpath -like '*..*') {
        throw "Path traversal detected in declared subpath '$($entry.subpath)' for third-party entry '$ComponentName'."
    }

    return $entry
}

function Test-DevKitPackageSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Policy = "data-only",

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedExtensions = @(".md", ".txt", ".json", ".yaml", ".yml"),

        [Parameter(Mandatory = $false)]
        [string[]]$DisallowedExtensions = @(".exe", ".bat", ".cmd", ".ps1", ".sh", ".js", ".mjs", ".cjs", ".dll", ".so", ".dylib", ".py", ".rb")
    )

    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "Package path does not exist or is not a directory: $Path"
    }

    $rootItem = Get-Item -LiteralPath $Path -Force
    $isRootReparse = ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    if ($isRootReparse) {
        throw "Symlink or reparse point detected in third-party package: $($rootItem.FullName)"
    }

    $normRoot = (Resolve-Path $Path).Path.TrimEnd('\', '/')
    $allItems = Get-ChildItem -LiteralPath $Path -Recurse -Force

    foreach ($item in $allItems) {
        # Check reparse point / symlink
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($isReparsePoint) {
            throw "Symlink or reparse point detected in third-party package: $($item.FullName)"
        }

        # Check path traversal: full name must stay strictly inside normRoot
        $itemNorm = $item.FullName
        if (-not $itemNorm.StartsWith($normRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and $itemNorm -ne $normRoot) {
            throw "Path traversal detected outside package root: $itemNorm"
        }

        if (-not $item.PSIsContainer) {
            $ext = [System.IO.Path]::GetExtension($item.Name).ToLowerInvariant()

            # Disallowed check
            if ($null -ne $DisallowedExtensions -and $DisallowedExtensions.Length -gt 0) {
                if ($DisallowedExtensions -contains $ext) {
                    throw "Forbidden file extension '$ext' detected in file '$($item.Name)' under policy '$Policy'."
                }
            }

            # Allowed check if data-only
            if ($Policy -eq "data-only" -and $null -ne $AllowedExtensions -and $AllowedExtensions.Length -gt 0) {
                if (-not ($AllowedExtensions -contains $ext)) {
                    throw "File extension '$ext' in '$($item.Name)' is not permitted under policy '$Policy'."
                }
            }
        }
    }
}

function Fetch-DevKitThirdParty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComponentName,

        [Parameter(Mandatory = $true)]
        [psobject]$RegistryEntry,

        [Parameter(Mandatory = $false)]
        [string]$MockDir = $null
    )

    $gitCmd = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if ($null -eq $gitCmd) {
        throw "git.exe is required for third-party component acquisition, but was not found in PATH."
    }

    $repo = $RegistryEntry.repo
    $ref = $RegistryEntry.ref
    $subpath = $RegistryEntry.subpath
    $policy = if ($RegistryEntry.policy) { $RegistryEntry.policy } else { "data-only" }
    $allowed = if ($RegistryEntry.allowedExtensions) { @($RegistryEntry.allowedExtensions) } else { @(".md", ".txt", ".json", ".yaml", ".yml") }
    $disallowed = if ($RegistryEntry.disallowedExtensions) { @($RegistryEntry.disallowedExtensions) } else { @(".exe", ".bat", ".cmd", ".ps1", ".sh", ".js", ".mjs", ".cjs", ".dll", ".so", ".dylib", ".py", ".rb") }

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-tp-git-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    try {
        $resolvedCommitSha = $ref

        if (-not [string]::IsNullOrWhiteSpace($MockDir)) {
            if (-not (Test-Path $MockDir -PathType Container)) {
                throw "Specified mock directory not found: $MockDir"
            }
            Copy-Item -Path "$MockDir\*" -Destination $tempBase -Recurse -Force
        }
        else {
            $remoteUrl = "https://github.com/$repo.git"
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"

            try {
                # 1. Initialize temporary isolated repository
                $initOut = (& $gitCmd.Source -c "core.hooksPath=" init $tempBase 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to initialize git sandbox for '$ComponentName': $initOut"
                }

                # 2. Add remote
                $remoteOut = (& $gitCmd.Source -c "core.hooksPath=" -C $tempBase remote add origin $remoteUrl 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to configure git remote for '$ComponentName': $remoteOut"
                }

                # 3. Fetch shallow commit without running hooks
                $fetchOut = (& $gitCmd.Source -c "core.hooksPath=" -C $tempBase fetch --depth 1 origin $ref 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0) {
                    # Fallback: fetch tag
                    $fetchOut = (& $gitCmd.Source -c "core.hooksPath=" -C $tempBase fetch --depth 1 origin "+refs/tags/$ref:refs/tags/$ref" 2>&1) | Out-String
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to fetch ref '$ref' from '$remoteUrl' for '$ComponentName': $fetchOut"
                    }
                }

                # 4. Checkout detached HEAD without running hooks
                $checkoutOut = (& $gitCmd.Source -c "core.hooksPath=" -c "advice.detachedHead=false" -C $tempBase checkout --force $ref 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to checkout ref '$ref' for '$ComponentName': $checkoutOut"
                }

                # 5. Mandatory validation: git rev-parse HEAD
                $headOut = (& $gitCmd.Source -c "core.hooksPath=" -C $tempBase rev-parse HEAD 2>&1) | Out-String
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headOut)) {
                    throw "Failed to resolve HEAD commit SHA for '$ComponentName': $headOut"
                }
                $resolvedCommitSha = $headOut.Trim().ToLowerInvariant()

                # If $ref is a full 40-character commit SHA, verify exact match
                if ($ref -match '^[a-fA-F0-9]{40}$') {
                    if ($resolvedCommitSha -ne $ref.ToLowerInvariant()) {
                        throw "Commit SHA verification failed for '$ComponentName': expected '$ref', resolved '$resolvedCommitSha'"
                    }
                }
            }
            finally {
                $ErrorActionPreference = $prevEap
            }
        }

        # 6. Validate subpath
        $normSubpath = $subpath.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::DirectorySeparatorChar)
        $targetSubpathDir = Join-Path $tempBase $normSubpath

        if (-not (Test-Path $targetSubpathDir -PathType Container)) {
            throw "Subpath '$subpath' does not exist in repository '$repo' at ref '$ref'."
        }

        # 7. Anti-traversal check: verify resolved path starts with tempBase root
        $resolvedRepoRoot = (Resolve-Path $tempBase).Path.TrimEnd('\', '/')
        $resolvedSubpath = (Resolve-Path $targetSubpathDir).Path
        if (-not $resolvedSubpath.StartsWith($resolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and $resolvedSubpath -ne $resolvedRepoRoot) {
            throw "Path traversal detected in subpath '$subpath' escaping repository root."
        }

        # 8. Test package security (symlinks/reparse points, allowed/disallowed extensions, policy)
        Test-DevKitPackageSecurity -Path $resolvedSubpath -Policy $policy -AllowedExtensions $allowed -DisallowedExtensions $disallowed

        # 9. Compute SHA-256 for all approved files
        $files = @{}
        $subpathFiles = Get-ChildItem -Path $resolvedSubpath -Recurse -File
        $subpathPrefix = $resolvedSubpath.TrimEnd('\', '/')

        foreach ($file in $subpathFiles) {
            $relPath = $file.FullName.Substring($subpathPrefix.Length).TrimStart('\', '/').Replace('\', '/')
            $hash = Get-DevKitSha256 -Path $file.FullName
            $files[$relPath] = @{
                sha256     = $hash
                length     = $file.Length
                sourcePath = $file.FullName
            }
        }

        return @{
            skillName     = $ComponentName
            source        = "third-party:github:$repo@$resolvedCommitSha"
            repo          = $repo
            ref           = $resolvedCommitSha
            subpath       = $subpath
            policy        = $policy
            license       = $RegistryEntry.license
            sourceDir     = $resolvedSubpath
            tempBase      = $tempBase
            files         = $files
            isThirdParty  = $true
        }
    }
    catch {
        if (Test-Path $tempBase) {
            Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
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
    if ($Manifest.thirdPartySkills) {
        foreach ($s in $Manifest.thirdPartySkills) {
            if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
        }
    }
    if ($Manifest.thirdParty) {
        foreach ($s in $Manifest.thirdParty) {
            if (-not $requestedSkills.Contains($s)) { $requestedSkills.Add($s) }
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

    # 1. Process Skills (Core, Profile, and Third-Party)
    foreach ($skillName in $requestedSkills) {
        $resolved = Resolve-DevKitComponent -SkillName $skillName -ProfileName $profile -DevKitRoot $DevKitRoot
        $isThirdParty = $false

        if ($null -eq $resolved) {
            # Check third-party registry
            $tpEntry = Resolve-DevKitThirdParty -ComponentName $skillName -DevKitRoot $DevKitRoot
            if ($null -ne $tpEntry) {
                $isThirdParty = $true
                $lockSkill = $null
                if ($null -ne $Lock -and $null -ne $Lock.skills) {
                    $lockSkill = $Lock.skills.$skillName
                }

                # Check if all target files already exist and match lock hashes
                $needFetch = ($null -eq $lockSkill -or $null -eq $lockSkill.files)
                if (-not $needFetch) {
                    foreach ($targetBase in $skillTargets) {
                        $targetSkillDir = Join-Path $ProjectDir (Join-Path $targetBase $skillName)
                        foreach ($prop in $lockSkill.files.PSObject.Properties) {
                            $targetFile = Join-Path $targetSkillDir $prop.Name.Replace('/', '\')
                            if (-not (Test-Path $targetFile -PathType Leaf)) {
                                $needFetch = $true
                                break
                            }
                        }
                        if ($needFetch) { break }
                    }
                }

                if ($needFetch) {
                    $resolved = Fetch-DevKitThirdParty -ComponentName $skillName -RegistryEntry $tpEntry
                }
                else {
                    $files = @{}
                    foreach ($prop in $lockSkill.files.PSObject.Properties) {
                        $files[$prop.Name] = @{
                            sha256 = $prop.Value.sha256
                        }
                    }
                    $resolved = @{
                        skillName    = $skillName
                        source       = $lockSkill.source
                        repo         = $lockSkill.repo
                        ref          = $lockSkill.ref
                        subpath      = $lockSkill.subpath
                        policy       = $lockSkill.policy
                        license      = $lockSkill.license
                        files        = $files
                        sourceDir    = $null
                        tempBase     = $null
                        isThirdParty = $true
                    }
                }
            }
        }

        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "skill"
                Component    = $skillName
                Skill        = $skillName
                File         = "*"
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Skill not found in DevKit core, profile $profile, or third-party registry"
                IsThirdParty = $false
                TempBase     = $null
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
                $sourcePath = if ($resolved.sourceDir) { Join-Path $resolved.sourceDir $relFile.Replace('/', '\') } else { $null }

                $results.Add([PSCustomObject]@{
                    Type         = "skill"
                    Component    = $skillName
                    Skill        = $skillName
                    File         = $relFile
                    Target       = $targetDisplay
                    TargetPath   = $targetFile
                    Source       = $resolved.source
                    SourcePath   = $sourcePath
                    Status       = $status
                    SourceHash   = $sourceHash
                    LockHash     = $lockHash
                    TargetHash   = $targetHash
                    Description  = $description
                    IsThirdParty = [bool]$resolved.isThirdParty
                    Repo         = $resolved.repo
                    Ref          = $resolved.ref
                    Subpath      = $resolved.subpath
                    Policy       = $resolved.policy
                    License      = $resolved.license
                    TempBase     = $resolved.tempBase
                })
            }
        }
    }

    # 2. Process Hooks
    foreach ($hookName in $requestedHooks) {
        $resolved = Resolve-DevKitHook -HookName $hookName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "hook"
                Component    = $hookName
                Skill        = $hookName
                File         = $hookName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Hook not found in DevKit core or profile $profile"
                IsThirdParty = $false
                TempBase     = $null
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
                Type         = "hook"
                Component    = $hookName
                Skill        = $hookName
                File         = $hookName
                Target       = $targetDisplay
                TargetPath   = $targetFile
                Source       = $resolved.source
                SourcePath   = $sourcePath
                Status       = $status
                SourceHash   = $sourceHash
                LockHash     = $lockHash
                TargetHash   = $targetHash
                Description  = $description
                IsThirdParty = $false
                TempBase     = $null
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

    try {
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
                    $skillEntry = @{
                        source  = $item.Source
                        version = "1.0.0"
                        files   = @{}
                    }
                    if ($item.IsThirdParty) {
                        $skillEntry["repo"] = $item.Repo
                        $skillEntry["ref"] = $item.Ref
                        $skillEntry["subpath"] = $item.Subpath
                        $skillEntry["policy"] = $item.Policy
                        $skillEntry["license"] = $item.License
                    }
                    $newLockSkills[$skillName] = $skillEntry
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
    }
    finally {
        # Always clean up any temporary directories used during fetch
        $cleanedBases = @{}
        foreach ($item in $state) {
            if ($item.TempBase -and (-not $cleanedBases.ContainsKey($item.TempBase))) {
                $cleanedBases[$item.TempBase] = $true
                if (Test-Path $item.TempBase) {
                    Remove-Item -Path $item.TempBase -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
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
    Get-DevKitThirdPartyRegistry, `
    Resolve-DevKitThirdParty, `
    Test-DevKitPackageSecurity, `
    Fetch-DevKitThirdParty, `
    Get-DevKitManifest, `
    Get-DevKitLock, `
    Save-DevKitLock, `
    Test-DevKitProjectState, `
    Invoke-DevKitSync, `
    Invoke-DevKitVerify, `
    Get-DevKitSkillCatalog, `
    Get-DevKitSkillInfo, `
    Get-DevKitProfileList, `
    Get-DevKitProfile, `
    Add-DevKitProfileSkill, `
    Remove-DevKitProfileSkill
