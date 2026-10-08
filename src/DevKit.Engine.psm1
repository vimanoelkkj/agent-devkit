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

function Test-DevKitSafeTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $true)]
        [string]$RelativeTarget
    )

    $resolvedProject = (Resolve-Path $ProjectDir).Path.TrimEnd('\', '/')
    $combined = [System.IO.Path]::GetFullPath((Join-Path $resolvedProject $RelativeTarget.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not $combined.StartsWith($resolvedProject + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and $combined -ne $resolvedProject) {
        throw "Path traversal detected: target '$RelativeTarget' escapes project root '$ProjectDir'."
    }
    return $combined
}

function Resolve-DevKitFileComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Subdir,

        [Parameter(Mandatory = $true)]
        [string]$ItemName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $normItem = $ItemName.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    $profilePath = Join-Path $DevKitRoot "profiles\$ProfileName\$Subdir\$normItem"
    $corePath = Join-Path $DevKitRoot "core\$Subdir\$normItem"

    $sourceType = $null
    $resolvedPath = $null

    if (Test-Path -Path $profilePath -PathType Leaf) {
        $sourceType = "profile:$ProfileName"
        $resolvedPath = $profilePath
    }
    elseif (Test-Path -Path $corePath -PathType Leaf) {
        $sourceType = "core"
        $resolvedPath = $corePath
    }
    else {
        return $null
    }

    $hash = Get-DevKitSha256 -Path $resolvedPath
    return @{
        category     = $Category
        name         = $ItemName
        source       = $sourceType
        sourcePath   = $resolvedPath
        sha256       = $hash
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

    $res = Resolve-DevKitFileComponent -Category "hook" -Subdir "hooks" -ItemName $HookName -ProfileName $ProfileName -DevKitRoot $DevKitRoot
    if ($null -eq $res) { return $null }
    return @{
        hookName     = $HookName
        source       = $res.source
        sourcePath   = $res.sourcePath
        sha256       = $res.sha256
    }
}

function Resolve-DevKitInstruction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstructionName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    return (Resolve-DevKitFileComponent -Category "instruction" -Subdir "instructions" -ItemName $InstructionName -ProfileName $ProfileName -DevKitRoot $DevKitRoot)
}

function Resolve-DevKitRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuleName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    return (Resolve-DevKitFileComponent -Category "rule" -Subdir "rules" -ItemName $RuleName -ProfileName $ProfileName -DevKitRoot $DevKitRoot)
}

function Resolve-DevKitAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AgentName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    return (Resolve-DevKitFileComponent -Category "agent" -Subdir "agents" -ItemName $AgentName -ProfileName $ProfileName -DevKitRoot $DevKitRoot)
}

function Resolve-DevKitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    return (Resolve-DevKitFileComponent -Category "config" -Subdir "configs" -ItemName $ConfigName -ProfileName $ProfileName -DevKitRoot $DevKitRoot)
}

function Resolve-DevKitOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverlayName,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    return (Resolve-DevKitFileComponent -Category "overlay" -Subdir "overlays" -ItemName $OverlayName -ProfileName $ProfileName -DevKitRoot $DevKitRoot)
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

function Find-DevKitProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,
        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot,
        [string]$HomeDir = $HOME,
        [string[]]$SearchRoots
    )

    $profile = Get-DevKitProfile -ProfileName $ProfileName -DevKitRoot $DevKitRoot
    $discovery = $profile.discovery
    if ($null -eq $discovery -or [string]::IsNullOrWhiteSpace($discovery.githubRepository)) {
        throw "Profile '$ProfileName' has no discovery.githubRepository. Use -ProjectDir or configure discovery."
    }

    $expected = [string]$discovery.githubRepository
    if ($expected -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') {
        throw "Invalid discovery.githubRepository for profile '$ProfileName'."
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    if ($PSBoundParameters.ContainsKey("SearchRoots")) {
        foreach ($root in $SearchRoots) {
            if ([string]::IsNullOrWhiteSpace($root)) {
                throw "SearchRoots cannot contain empty paths."
            }
            $roots.Add($root)
        }
        if ($roots.Count -eq 0) { throw "SearchRoots cannot be empty." }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($HomeDir)) {
            throw "HOME is unavailable; pass -SearchRoots."
        }
        foreach ($relative in @($discovery.homeDirectories)) {
            if ([string]::IsNullOrWhiteSpace($relative) -or
                [System.IO.Path]::IsPathRooted($relative) -or
                $relative -match '[\\/]' -or
                $relative -in @(".", "..")) {
                throw "Invalid homeDirectories entry in profile '$ProfileName'."
            }
            $roots.Add((Join-Path $HomeDir $relative))
        }
        if ($roots.Count -eq 0) {
            throw "Profile '$ProfileName' has no discovery.homeDirectories; pass -SearchRoots."
        }
    }

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is required for -AutoDiscover. No project was modified."
    }

    $found = [System.Collections.Generic.List[string]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($searchRoot in $roots) {
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { continue }
        $rootDir = (Resolve-Path -LiteralPath $searchRoot).Path
        $candidates = [System.Collections.Generic.List[string]]::new()
        $candidates.Add($rootDir)

        # Bounded search: root itself and its immediate child folders only.
        foreach ($child in @(Get-ChildItem -LiteralPath $rootDir -Directory -ErrorAction Stop)) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $candidates.Add($child.FullName)
        }

        foreach ($candidate in $candidates) {
            $path = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
            if (-not $visited.Add($path)) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $path ".git"))) { continue }

            $markersPresent = $true
            foreach ($marker in @($discovery.markers)) {
                if ([string]::IsNullOrWhiteSpace($marker) -or
                    [System.IO.Path]::IsPathRooted($marker) -or
                    $marker -match '[\\/]' -or $marker -in @(".", "..")) {
                    throw "Invalid discovery.markers entry in profile '$ProfileName'."
                }
                if (-not (Test-Path -LiteralPath (Join-Path $path $marker) -PathType Leaf)) {
                    $markersPresent = $false
                    break
                }
            }
            if (-not $markersPresent) { continue }

            try {
                $topLevel = & git -C $path rev-parse --show-toplevel 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $topLevel) { continue }
                $repoRoot = [System.IO.Path]::GetFullPath([string](@($topLevel)[0])).TrimEnd('\', '/')
                if (-not [string]::Equals($repoRoot, $path, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                # Only read local Git configuration; do not run Git hooks or call any network.
                $origin = & git -C $path config --get remote.origin.url 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $origin) { continue }
                $remote = ([string](@($origin)[0])).Trim()
                if ($remote -notmatch '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)/?$') {
                    continue
                }
                $repoName = $Matches[1] -replace '\.git$', ''
                if ([string]::Equals($repoName, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $found.Add($path)
                }
            }
            catch {
                # Never trust an inaccessible or malformed Git directory as a target.
                continue
            }
        }
    }

    if ($found.Count -eq 0) {
        throw "No matching Git checkout of '$expected' found for profile '$ProfileName'. Check HOME search directories or use -SearchRoots / -ProjectDir. No files changed."
    }
    if ($found.Count -gt 1) {
        throw "Ambiguous project discovery for '$expected': $($found -join '; '). Choose one with -ProjectDir. No files changed."
    }

    return $found[0]
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

            $instructionsCount = if ($obj.instructions) { $obj.instructions.Count } else { 0 }
            $rulesCount = if ($obj.rules) { $obj.rules.Count } else { 0 }
            $agentsCount = if ($obj.agents) { $obj.agents.Count } else { 0 }
            $configsCount = if ($obj.configs) { $obj.configs.Count } else { 0 }
            $overlaysCount = if ($obj.overlays) { $obj.overlays.Count } else { 0 }

            $results.Add([PSCustomObject]@{
                Name              = $obj.name
                Version           = $obj.version
                Description       = $obj.description
                SkillsCount       = $skillsCount
                ThirdPartyCount   = $tpSkillsCount
                TotalSkillsCount  = $skillsCount + $tpSkillsCount
                HooksCount        = $hooksCount
                InstructionsCount = $instructionsCount
                RulesCount        = $rulesCount
                AgentsCount       = $agentsCount
                ConfigsCount      = $configsCount
                OverlaysCount     = $overlaysCount
                AvailableCount    = $undeclaredCount
                Path              = $profileFile
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

function New-DevKitManifestFromProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    $profileObj = Get-DevKitProfile -ProfileName $ProfileName -DevKitRoot $DevKitRoot

    return [PSCustomObject]@{
        profile          = $ProfileName
        skills           = if ($profileObj.skills) { @($profileObj.skills) } else { @() }
        thirdPartySkills = if ($profileObj.thirdPartySkills) { @($profileObj.thirdPartySkills) } else { @() }
        hooks            = if ($profileObj.hooks) { @($profileObj.hooks) } else { @() }
        instructions     = if ($profileObj.instructions) { @($profileObj.instructions) } else { @() }
        rules            = if ($profileObj.rules) { @($profileObj.rules) } else { @() }
        agents           = if ($profileObj.agents) { @($profileObj.agents) } else { @() }
        configs          = if ($profileObj.configs) { @($profileObj.configs) } else { @() }
        overlays         = if ($profileObj.overlays) { @($profileObj.overlays) } else { @() }
        targets          = $profileObj.targets
    }
}

function Get-DevKitLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = $null,

        [Parameter(Mandatory = $false)]
        [string]$StateDir = $null,

        [Parameter(Mandatory = $false)]
        [string]$DevKitRoot = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        return (Join-Path $StateDir "agent-devkit.lock")
    }

    $projectManifest = Join-Path $ProjectDir "agent-devkit.json"
    if (Test-Path -Path $projectManifest -PathType Leaf) {
        return (Join-Path $ProjectDir "agent-devkit.lock")
    }

    if (-not [string]::IsNullOrWhiteSpace($ProfileName) -and -not [string]::IsNullOrWhiteSpace($DevKitRoot)) {
        $stateBase = Join-Path $DevKitRoot "state\$ProfileName"
        return (Join-Path $stateBase "agent-devkit.lock")
    }

    return (Join-Path $ProjectDir "agent-devkit.lock")
}

function Get-DevKitLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = $null,

        [Parameter(Mandatory = $false)]
        [string]$StateDir = $null,

        [Parameter(Mandatory = $false)]
        [string]$DevKitRoot = $null
    )

    $lockPath = Get-DevKitLockPath -ProjectDir $ProjectDir -ProfileName $ProfileName -StateDir $StateDir -DevKitRoot $DevKitRoot
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
        [psobject]$LockObject,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = $null,

        [Parameter(Mandatory = $false)]
        [string]$StateDir = $null,

        [Parameter(Mandatory = $false)]
        [string]$DevKitRoot = $null
    )

    $lockPath = Get-DevKitLockPath -ProjectDir $ProjectDir -ProfileName $ProfileName -StateDir $StateDir -DevKitRoot $DevKitRoot
    $lockDir = Split-Path -Parent $lockPath
    if (-not (Test-Path $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }

    $json = $LockObject | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($lockPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-DevKitSingleFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$File,

        [Parameter(Mandatory = $true)]
        [string]$TargetDisplay,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $false)]
        [string]$Source = $null,

        [Parameter(Mandatory = $false)]
        [string]$SourcePath = $null,

        [Parameter(Mandatory = $false)]
        [string]$SourceHash = $null,

        [Parameter(Mandatory = $false)]
        [string]$LockHash = $null
    )

    $targetExists = Test-Path -Path $TargetPath -PathType Leaf
    $targetHash = if ($targetExists) { Get-DevKitSha256 -Path $TargetPath } else { $null }

    $status = "unknown"
    $description = ""

    if (-not $targetExists) {
        $status = "missing"
        $description = "$Type does not exist in target"
    }
    elseif ($null -eq $LockHash) {
        if ($targetHash -eq $SourceHash) {
            $status = "synced"
            $description = "$Type matches source exactly"
        }
        else {
            $status = "modified"
            $description = "Local target $Type differs from source (unlocked)"
        }
    }
    else {
        $targetMatchesLock = ($targetHash -eq $LockHash)
        $sourceMatchesLock = ($SourceHash -eq $LockHash)

        if ($targetMatchesLock -and $sourceMatchesLock) {
            $status = "synced"
            $description = "$Type matches lock and source exactly"
        }
        elseif ($targetMatchesLock -and (-not $sourceMatchesLock)) {
            $status = "update_available"
            $description = "Upstream $Type updated; target is cleanly at lock version"
        }
        elseif ((-not $targetMatchesLock) -and $sourceMatchesLock) {
            $status = "modified"
            $description = "Local target $Type modified; source unchanged"
        }
        else {
            $status = "conflict"
            $description = "Both local target and source differ from lock"
        }
    }

    return [PSCustomObject]@{
        Type         = $Type
        Component    = $Component
        Skill        = $Component
        File         = $File
        Target       = $TargetDisplay
        TargetPath   = $TargetPath
        Source       = $Source
        SourcePath   = $SourcePath
        Status       = $status
        SourceHash   = $SourceHash
        LockHash     = $LockHash
        TargetHash   = $targetHash
        Description  = $description
        IsThirdParty = $false
        TempBase     = $null
    }
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

    # Extract requested instructions
    $requestedInstructions = [System.Collections.Generic.List[string]]::new()
    if ($Manifest.instructions) {
        foreach ($i in $Manifest.instructions) {
            if (-not $requestedInstructions.Contains($i)) { $requestedInstructions.Add($i) }
        }
    }

    # Extract requested rules
    $requestedRules = [System.Collections.Generic.List[string]]::new()
    if ($Manifest.rules) {
        foreach ($r in $Manifest.rules) {
            if (-not $requestedRules.Contains($r)) { $requestedRules.Add($r) }
        }
    }

    # Extract requested agents
    $requestedAgents = [System.Collections.Generic.List[string]]::new()
    if ($Manifest.agents) {
        foreach ($a in $Manifest.agents) {
            if (-not $requestedAgents.Contains($a)) { $requestedAgents.Add($a) }
        }
    }

    # Extract requested configs
    $requestedConfigs = [System.Collections.Generic.List[object]]::new()
    if ($Manifest.configs) {
        foreach ($c in $Manifest.configs) {
            $requestedConfigs.Add($c)
        }
    }

    # Extract requested overlays
    $requestedOverlays = [System.Collections.Generic.List[object]]::new()
    if ($Manifest.overlays) {
        foreach ($o in $Manifest.overlays) {
            $requestedOverlays.Add($o)
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

        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.hooks -and $null -ne $Lock.hooks.$hookName) { $Lock.hooks.$hookName.sha256 } else { $null }

        foreach ($targetBase in $hookTargets) {
            $relTarget = Join-Path $targetBase $hookName
            $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $relTarget
            $targetDisplay = $relTarget.Replace('\', '/')

            $results.Add((Get-DevKitSingleFileState -Type "hook" `
                -Component $hookName `
                -File $hookName `
                -TargetDisplay $targetDisplay `
                -TargetPath $targetFile `
                -Source $resolved.source `
                -SourcePath $resolved.sourcePath `
                -SourceHash $resolved.sha256 `
                -LockHash $lockHash))
        }
    }

    # 3. Process Instructions
    foreach ($instName in $requestedInstructions) {
        $resolved = Resolve-DevKitInstruction -InstructionName $instName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "instruction"
                Component    = $instName
                Skill        = $instName
                File         = $instName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Instruction not found in DevKit profile $profile or core"
                IsThirdParty = $false
                TempBase     = $null
            })
            continue
        }

        $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $instName
        $targetDisplay = $instName.Replace('\', '/')
        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.instructions -and $null -ne $Lock.instructions.$instName) { $Lock.instructions.$instName.sha256 } else { $null }

        $results.Add((Get-DevKitSingleFileState -Type "instruction" `
            -Component $instName `
            -File $instName `
            -TargetDisplay $targetDisplay `
            -TargetPath $targetFile `
            -Source $resolved.source `
            -SourcePath $resolved.sourcePath `
            -SourceHash $resolved.sha256 `
            -LockHash $lockHash))
    }

    # 4. Process Rules
    foreach ($ruleName in $requestedRules) {
        $resolved = Resolve-DevKitRule -RuleName $ruleName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "rule"
                Component    = $ruleName
                Skill        = $ruleName
                File         = $ruleName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Rule not found in DevKit profile $profile or core"
                IsThirdParty = $false
                TempBase     = $null
            })
            continue
        }

        $normRule = $ruleName.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
        $relTarget = Join-Path ".claude\rules" $normRule
        $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $relTarget
        $targetDisplay = $relTarget.Replace('\', '/')
        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.rules -and $null -ne $Lock.rules.$ruleName) { $Lock.rules.$ruleName.sha256 } else { $null }

        $results.Add((Get-DevKitSingleFileState -Type "rule" `
            -Component $ruleName `
            -File $ruleName `
            -TargetDisplay $targetDisplay `
            -TargetPath $targetFile `
            -Source $resolved.source `
            -SourcePath $resolved.sourcePath `
            -SourceHash $resolved.sha256 `
            -LockHash $lockHash))
    }

    # 5. Process Agents
    foreach ($agentName in $requestedAgents) {
        $resolved = Resolve-DevKitAgent -AgentName $agentName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "agent"
                Component    = $agentName
                Skill        = $agentName
                File         = $agentName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Agent not found in DevKit profile $profile or core"
                IsThirdParty = $false
                TempBase     = $null
            })
            continue
        }

        $normAgent = $agentName.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
        $relTarget = Join-Path ".claude\agents" $normAgent
        $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $relTarget
        $targetDisplay = $relTarget.Replace('\', '/')
        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.agents -and $null -ne $Lock.agents.$agentName) { $Lock.agents.$agentName.sha256 } else { $null }

        $results.Add((Get-DevKitSingleFileState -Type "agent" `
            -Component $agentName `
            -File $agentName `
            -TargetDisplay $targetDisplay `
            -TargetPath $targetFile `
            -Source $resolved.source `
            -SourcePath $resolved.sourcePath `
            -SourceHash $resolved.sha256 `
            -LockHash $lockHash))
    }

    # 6. Process Configs
    foreach ($cfg in $requestedConfigs) {
        $cfgName = if ($cfg -is [string]) { $cfg } else { $cfg.source }
        $cfgTarget = if ($cfg -is [string]) {
            if ($cfg -eq "settings.json") { ".claude\settings.json" } else { Join-Path ".claude" $cfg }
        } else {
            $cfg.target
        }

        $resolved = Resolve-DevKitConfig -ConfigName $cfgName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "config"
                Component    = $cfgName
                Skill        = $cfgName
                File         = $cfgName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Config not found in DevKit profile $profile or core"
                IsThirdParty = $false
                TempBase     = $null
            })
            continue
        }

        $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $cfgTarget
        $targetDisplay = $cfgTarget.Replace('\', '/')
        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.configs -and $null -ne $Lock.configs.$cfgName) { $Lock.configs.$cfgName.sha256 } else { $null }

        $results.Add((Get-DevKitSingleFileState -Type "config" `
            -Component $cfgName `
            -File $cfgName `
            -TargetDisplay $targetDisplay `
            -TargetPath $targetFile `
            -Source $resolved.source `
            -SourcePath $resolved.sourcePath `
            -SourceHash $resolved.sha256 `
            -LockHash $lockHash))
    }

    # 7. Process Overlays
    foreach ($ov in $requestedOverlays) {
        $ovName = if ($ov -is [string]) { $ov } else { $ov.source }
        $ovTarget = if ($ov -is [string]) { $ov } else { $ov.target }

        $resolved = Resolve-DevKitOverlay -OverlayName $ovName -ProfileName $profile -DevKitRoot $DevKitRoot
        if ($null -eq $resolved) {
            $results.Add([PSCustomObject]@{
                Type         = "overlay"
                Component    = $ovName
                Skill        = $ovName
                File         = $ovName
                Target       = "*"
                TargetPath   = $null
                Source       = $null
                SourcePath   = $null
                Status       = "unresolved"
                SourceHash   = $null
                LockHash     = $null
                TargetHash   = $null
                Description  = "Overlay not found in DevKit profile $profile or core"
                IsThirdParty = $false
                TempBase     = $null
            })
            continue
        }

        $targetFile = Test-DevKitSafeTargetPath -ProjectDir $ProjectDir -RelativeTarget $ovTarget
        $targetDisplay = $ovTarget.Replace('\', '/')
        $lockHash = if ($null -ne $Lock -and $null -ne $Lock.overlays -and $null -ne $Lock.overlays.$ovName) { $Lock.overlays.$ovName.sha256 } else { $null }

        $results.Add((Get-DevKitSingleFileState -Type "overlay" `
            -Component $ovName `
            -File $ovName `
            -TargetDisplay $targetDisplay `
            -TargetPath $targetFile `
            -Source $resolved.source `
            -SourcePath $resolved.sourcePath `
            -SourceHash $resolved.sha256 `
            -LockHash $lockHash))
    }

    return $results
}

function Set-DevKitGitExclude {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePaths = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Remove
    )

    $gitDir = $null
    $dotGit = Join-Path $ProjectDir ".git"
    if (Test-Path $dotGit -PathType Container) {
        $gitDir = $dotGit
    } elseif (Test-Path $dotGit -PathType Leaf) {
        $gitContent = Get-Content $dotGit -Raw -ErrorAction SilentlyContinue
        if ($gitContent -match 'gitdir:\s*(.+)') {
            $rawPath = $matches[1].Trim()
            if ([System.IO.Path]::IsPathRooted($rawPath)) {
                $gitDir = $rawPath
            } else {
                $gitDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $rawPath))
            }
        }
    }

    if (-not $gitDir -or -not (Test-Path $gitDir)) {
        return [PSCustomObject]@{
            Updated = $false
            Reason  = "NoGitRepository"
            File    = $null
            Entries = @()
        }
    }

    $infoDir = Join-Path $gitDir "info"
    if (-not (Test-Path $infoDir -PathType Container)) {
        New-Item -ItemType Directory -Path $infoDir -Force | Out-Null
    }
    $excludeFile = Join-Path $infoDir "exclude"

    $startMarker = "# BEGIN AGENT-DEVKIT MANAGED EXCLUDES"
    $endMarker = "# END AGENT-DEVKIT MANAGED EXCLUDES"

    $existingContent = ""
    if (Test-Path $excludeFile -PathType Leaf) {
        $existingContent = [System.IO.File]::ReadAllText($excludeFile, [System.Text.Encoding]::UTF8)
    }

    $pattern = [regex]::Escape($startMarker) + '[\s\S]*?' + [regex]::Escape($endMarker)
    $hasBlock = [regex]::IsMatch($existingContent, $pattern)
    $cleanContent = ""
    if ($hasBlock) {
        $cleanContent = [regex]::Replace($existingContent, $pattern, "").TrimEnd()
    } else {
        $cleanContent = $existingContent.TrimEnd()
    }

    if ($Remove) {
        $finalText = if ([string]::IsNullOrWhiteSpace($cleanContent)) { "" } else { $cleanContent + "`n" }
        if ($existingContent -ne $finalText) {
            [System.IO.File]::WriteAllText($excludeFile, $finalText, [System.Text.Encoding]::UTF8)
        }
        return [PSCustomObject]@{
            Updated = $true
            Removed = $true
            File    = $excludeFile
            Entries = @()
        }
    }

    $normalized = @()
    foreach ($p in $ExcludePaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $entry = $p.Trim().Replace('\', '/')
        if (-not $normalized.Contains($entry)) {
            $normalized += $entry
        }
    }
    $sortedEntries = $normalized | Sort-Object

    $managedBlockLines = @(
        $startMarker
        "# Generated by agent-devkit. Do not edit this block manually."
    )
    $managedBlockLines += $sortedEntries
    $managedBlockLines += $endMarker
    $managedBlock = ($managedBlockLines -join "`n")

    $newContent = if ([string]::IsNullOrWhiteSpace($cleanContent)) {
        $managedBlock + "`n"
    } else {
        $cleanContent + "`n`n" + $managedBlock + "`n"
    }

    if ($existingContent -ne $newContent) {
        [System.IO.File]::WriteAllText($excludeFile, $newContent, [System.Text.Encoding]::UTF8)
    }

    return [PSCustomObject]@{
        Updated = $true
        Removed = $false
        File    = $excludeFile
        Entries = $sortedEntries
    }
}

function Get-DevKitProfileExcludePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Manifest = $null,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = $null,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalPaths = @()
    )

    if ($null -eq $Manifest -and -not [string]::IsNullOrWhiteSpace($ProfileName)) {
        $Manifest = New-DevKitManifestFromProfile -ProfileName $ProfileName -DevKitRoot $DevKitRoot
    }

    $paths = [System.Collections.Generic.List[string]]::new()

    if ($Manifest.instructions) {
        foreach ($inst in $Manifest.instructions) {
            $name = if ($inst -is [string]) { $inst } else { $inst.target }
            if ($name -and -not $paths.Contains($name)) { $paths.Add($name.Replace('\', '/')) }
        }
    }

    $hasSkills = ($Manifest.skills -and $Manifest.skills.Count -gt 0) -or ($Manifest.thirdPartySkills -and $Manifest.thirdPartySkills.Count -gt 0)
    if ($hasSkills) {
        if (-not $paths.Contains(".agents/")) { $paths.Add(".agents/") }
        if (-not $paths.Contains(".claude/")) { $paths.Add(".claude/") }
    }

    $hasClaude = ($Manifest.hooks -and $Manifest.hooks.Count -gt 0) -or
                 ($Manifest.rules -and $Manifest.rules.Count -gt 0) -or
                 ($Manifest.agents -and $Manifest.agents.Count -gt 0) -or
                 ($Manifest.configs -and $Manifest.configs.Count -gt 0)
    if ($hasClaude -and -not $paths.Contains(".claude/")) {
        $paths.Add(".claude/")
    }

    if ($Manifest.overlays) {
        foreach ($ov in $Manifest.overlays) {
            $target = if ($ov -is [string]) { $ov } else { $ov.target }
            if ($target -and -not $paths.Contains($target)) {
                $paths.Add($target.Replace('\', '/'))
            }
        }
    }

    $profName = if ($Manifest.profile) { $Manifest.profile.Split('@')[0] } else { $ProfileName }
    if ($profName -eq "rp-doces") {
        $knownLocal = @(
            ".mcp.json",
            ".graphifyignore",
            "graphify-out/",
            ".codex/",
            ".qoder/"
        )
        foreach ($kl in $knownLocal) {
            if (-not $paths.Contains($kl)) {
                $paths.Add($kl)
            }
        }
    }

    foreach ($ap in $AdditionalPaths) {
        if ($ap -and -not $paths.Contains($ap)) {
            $paths.Add($ap.Replace('\', '/'))
        }
    }

    return $paths.ToArray()
}

function Invoke-DevKitSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectDir,

        [Parameter(Mandatory = $false)]
        [string]$Profile = $null,

        [Parameter(Mandatory = $false)]
        [string]$StateDir = $null,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [switch]$NoGitExclude,

        [Parameter(Mandatory = $false)]
        [psobject]$Manifest = $null,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    if ($null -eq $Manifest) {
        if (-not [string]::IsNullOrWhiteSpace($Profile)) {
            $Manifest = New-DevKitManifestFromProfile -ProfileName $Profile -DevKitRoot $DevKitRoot
        } else {
            $Manifest = Get-DevKitManifest -ProjectDir $ProjectDir
        }
    }
    if ($null -eq $Manifest) {
        throw "Manifest agent-devkit.json not found in $ProjectDir and no -Profile specified."
    }

    $activeProfile = if (-not [string]::IsNullOrWhiteSpace($Profile)) { $Profile } else { $Manifest.profile }
    $lock = Get-DevKitLock -ProjectDir $ProjectDir -ProfileName $activeProfile -StateDir $StateDir -DevKitRoot $DevKitRoot
    $state = Test-DevKitProjectState -ProjectDir $ProjectDir -Manifest $Manifest -Lock $lock -DevKitRoot $DevKitRoot

    $syncedCount = 0
    $materializedCount = 0
    $blockedCount = 0
    $missingCount = 0

    $newLockSkills = @{}
    $newLockHooks = @{}
    $newLockInstructions = @{}
    $newLockRules = @{}
    $newLockAgents = @{}
    $newLockConfigs = @{}
    $newLockOverlays = @{}

    try {
        foreach ($item in $state) {
            switch ($item.Type) {
                "hook" {
                    if (-not $newLockHooks.ContainsKey($item.Component)) {
                        $newLockHooks[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "instruction" {
                    if (-not $newLockInstructions.ContainsKey($item.Component)) {
                        $newLockInstructions[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "rule" {
                    if (-not $newLockRules.ContainsKey($item.Component)) {
                        $newLockRules[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "agent" {
                    if (-not $newLockAgents.ContainsKey($item.Component)) {
                        $newLockAgents[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "config" {
                    if (-not $newLockConfigs.ContainsKey($item.Component)) {
                        $newLockConfigs[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "overlay" {
                    if (-not $newLockOverlays.ContainsKey($item.Component)) {
                        $newLockOverlays[$item.Component] = @{
                            source = $item.Source
                            sha256 = $item.SourceHash
                        }
                    }
                }
                "skill" {
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
                profile         = "$activeProfile@1.0.0"
                skills          = $newLockSkills
                hooks           = $newLockHooks
                instructions    = $newLockInstructions
                rules           = $newLockRules
                agents          = $newLockAgents
                configs         = $newLockConfigs
                overlays        = $newLockOverlays
            }
            Save-DevKitLock -ProjectDir $ProjectDir -LockObject $newLock -ProfileName $activeProfile -StateDir $StateDir -DevKitRoot $DevKitRoot

            if (-not $NoGitExclude) {
                $excludePaths = Get-DevKitProfileExcludePaths -Manifest $Manifest -ProfileName $activeProfile -DevKitRoot $DevKitRoot
                Set-DevKitGitExclude -ProjectDir $ProjectDir -ExcludePaths $excludePaths | Out-Null
            }
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
        [string]$Profile = $null,

        [Parameter(Mandatory = $false)]
        [string]$StateDir = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$Manifest = $null,

        [Parameter(Mandatory = $true)]
        [string]$DevKitRoot
    )

    if ($null -eq $Manifest) {
        if (-not [string]::IsNullOrWhiteSpace($Profile)) {
            $Manifest = New-DevKitManifestFromProfile -ProfileName $Profile -DevKitRoot $DevKitRoot
        } else {
            $Manifest = Get-DevKitManifest -ProjectDir $ProjectDir
        }
    }
    if ($null -eq $Manifest) {
        throw "Manifest agent-devkit.json not found in $ProjectDir and no -Profile specified."
    }

    $activeProfile = if (-not [string]::IsNullOrWhiteSpace($Profile)) { $Profile } else { $Manifest.profile }
    $lock = Get-DevKitLock -ProjectDir $ProjectDir -ProfileName $activeProfile -StateDir $StateDir -DevKitRoot $DevKitRoot
    $state = Test-DevKitProjectState -ProjectDir $ProjectDir -Manifest $Manifest -Lock $lock -DevKitRoot $DevKitRoot

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
    Test-DevKitSafeTargetPath, `
    Resolve-DevKitComponent, `
    Resolve-DevKitFileComponent, `
    Resolve-DevKitHook, `
    Resolve-DevKitInstruction, `
    Resolve-DevKitRule, `
    Resolve-DevKitAgent, `
    Resolve-DevKitConfig, `
    Resolve-DevKitOverlay, `
    Get-DevKitThirdPartyRegistry, `
    Resolve-DevKitThirdParty, `
    Test-DevKitPackageSecurity, `
    Fetch-DevKitThirdParty, `
    Get-DevKitManifest, `
    New-DevKitManifestFromProfile, `
    Get-DevKitLockPath, `
    Get-DevKitLock, `
    Save-DevKitLock, `
    Get-DevKitSingleFileState, `
    Test-DevKitProjectState, `
    Invoke-DevKitSync, `
    Invoke-DevKitVerify, `
    Get-DevKitSkillCatalog, `
    Get-DevKitSkillInfo, `
    Find-DevKitProject, `
    Get-DevKitProfileList, `
    Get-DevKitProfile, `
    Add-DevKitProfileSkill, `
    Remove-DevKitProfileSkill, `
    Set-DevKitGitExclude, `
    Get-DevKitProfileExcludePaths
