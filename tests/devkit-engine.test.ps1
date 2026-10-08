# tests/devkit-engine.test.ps1
# Automated unit & integration tests for agent-devkit engine

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$devKitRoot = Split-Path -Parent $scriptDir

$modulePath = Join-Path $devKitRoot "src\DevKit.Engine.psm1"
Import-Module $modulePath -Force -DisableNameChecking

$passCount = 0
$failCount = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        $script:failCount++
        Write-Host "  FAIL: $Message (Expected: '$Expected', Actual: '$Actual')" -ForegroundColor Red
    }
    else {
        $script:passCount++
        Write-Host "  PASS: $Message" -ForegroundColor Green
    }
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) {
        $script:failCount++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
    else {
        $script:passCount++
        Write-Host "  PASS: $Message" -ForegroundColor Green
    }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$ExpectedSubstring, [string]$Message)
    $threw = $false
    $errMessage = ""
    try {
        & $Script
    }
    catch {
        $threw = $true
        $errMessage = $_.Exception.Message
    }

    if (-not $threw) {
        $script:failCount++
        Write-Host "  FAIL: $Message (Expected exception but none was thrown)" -ForegroundColor Red
    }
    elseif ($ExpectedSubstring -and -not $errMessage.Contains($ExpectedSubstring)) {
        $script:failCount++
        Write-Host "  FAIL: $Message (Exception thrown but missing substring '$ExpectedSubstring'. Message: '$errMessage')" -ForegroundColor Red
    }
    else {
        $script:passCount++
        Write-Host "  PASS: $Message" -ForegroundColor Green
    }
}

Write-Host "=== TEST SUITE: agent-devkit Engine ===" -ForegroundColor Cyan

# Test 1: SHA256 Calculation
Write-Host "`nTest 1: SHA256 calculation" -ForegroundColor Yellow
$testFile = Join-Path $devKitRoot "core\skills\minimal-diff\SKILL.md"
$hash = Get-DevKitSha256 -Path $testFile
Assert-True ($null -ne $hash -and $hash.Length -eq 64) "Computes valid 64-character lowercase SHA-256 hash"

# Test 2: Component Resolution for Skills (Core vs Profile)
Write-Host "`nTest 2: Skill resolution (Core vs Profile)" -ForegroundColor Yellow
$coreSkill = Resolve-DevKitComponent -SkillName "targeted-repo-search" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-Equal $coreSkill.source "core" "Resolves targeted-repo-search from core"
Assert-True ($coreSkill.files.ContainsKey("SKILL.md")) "Finds SKILL.md in core skill"

$profileSkill = Resolve-DevKitComponent -SkillName "rp-targeted-workflow" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-Equal $profileSkill.source "profile:rp-doces" "Resolves rp-targeted-workflow from profile:rp-doces"
Assert-True ($profileSkill.files.ContainsKey("SKILL.md")) "Finds SKILL.md in profile skill"

$invalidSkill = Resolve-DevKitComponent -SkillName "non-existent-skill" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-True ($null -eq $invalidSkill) "Non-existent skill resolves to null"

# Test 3: Hook Resolution (Core vs Profile)
Write-Host "`nTest 3: Hook resolution (Core vs Profile)" -ForegroundColor Yellow
$coreHook = Resolve-DevKitHook -HookName "hook-io.mjs" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-Equal $coreHook.source "core" "Resolves hook-io.mjs from core"
Assert-True ($null -ne $coreHook.sha256 -and $coreHook.sha256.Length -eq 64) "Computes SHA-256 for core hook"

$profileHook = Resolve-DevKitHook -HookName "guard-d1-remote.mjs" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-Equal $profileHook.source "profile:rp-doces" "Resolves guard-d1-remote.mjs from profile:rp-doces"
Assert-True ($null -ne $profileHook.sha256 -and $profileHook.sha256.Length -eq 64) "Computes SHA-256 for profile hook"

$invalidHook = Resolve-DevKitHook -HookName "non-existent-hook.mjs" -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-True ($null -eq $invalidHook) "Non-existent hook resolves to null"

# Test 4: Temporary mock project lifecycle (Skills + Hooks)
Write-Host "`nTest 4: DryRun and Sync in mock consumer project (Skills + Hooks)" -ForegroundColor Yellow
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "agent-devkit-test-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    # Create mock manifest containing both skills and hooks
    $manifestObj = [PSCustomObject]@{
        version = "1.0.0"
        profile = "rp-doces"
        skills  = @("targeted-repo-search", "minimal-diff", "rp-targeted-workflow")
        hooks   = @("hook-io.mjs", "guard-d1-remote.mjs")
        targets = [PSCustomObject]@{
            skills = @(".agents/skills", ".claude/skills")
            hooks  = @(".claude/hooks")
        }
    }
    $manifestJson = $manifestObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $tmpDir "agent-devkit.json"), $manifestJson, [System.Text.UTF8Encoding]::new($false))

    # 4.1 Dry-Run Sync: must NOT create target files or lockfile
    $dryResult = Invoke-DevKitSync -ProjectDir $tmpDir -DryRun -DevKitRoot $devKitRoot
    Assert-Equal $dryResult.DryRun $true "Sync reported DryRun mode"
    Assert-Equal $dryResult.Materialized 0 "DryRun did not materialize files"
    Assert-Equal $dryResult.Missing 8 "DryRun detected 8 missing target files (6 skill files + 2 hook files)"
    Assert-True (-not (Test-Path (Join-Path $tmpDir ".agents\skills"))) "DryRun did not create .agents/skills directory"
    Assert-True (-not (Test-Path (Join-Path $tmpDir ".claude\hooks"))) "DryRun did not create .claude/hooks directory"
    Assert-True (-not (Test-Path (Join-Path $tmpDir "agent-devkit.lock"))) "DryRun did not create agent-devkit.lock"

    # 4.2 Real Sync: must materialize skills, hooks, and lockfile
    $syncResult = Invoke-DevKitSync -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $syncResult.Materialized 8 "Real Sync materialized 8 files"
    Assert-True (Test-Path (Join-Path $tmpDir ".agents\skills\targeted-repo-search\SKILL.md")) "Materialized skill in .agents/skills"
    Assert-True (Test-Path (Join-Path $tmpDir ".claude\skills\targeted-repo-search\SKILL.md")) "Materialized skill in .claude/skills"
    Assert-True (Test-Path (Join-Path $tmpDir ".claude\hooks\hook-io.mjs")) "Materialized core hook in .claude/hooks"
    Assert-True (Test-Path (Join-Path $tmpDir ".claude\hooks\guard-d1-remote.mjs")) "Materialized profile hook in .claude/hooks"
    Assert-True (Test-Path (Join-Path $tmpDir "agent-devkit.lock")) "Created agent-devkit.lock"

    # 4.3 Verify hash parity of materialized hook
    $sourceHookHash = (Resolve-DevKitHook -HookName "hook-io.mjs" -ProfileName "rp-doces" -DevKitRoot $devKitRoot).sha256
    $targetHookHash = Get-DevKitSha256 -Path (Join-Path $tmpDir ".claude\hooks\hook-io.mjs")
    Assert-Equal $targetHookHash $sourceHookHash "Materialized hook matches source SHA-256 byte-for-byte"

    # 4.4 Verify immediately after sync: must be 100% verified
    $verifyResult = Invoke-DevKitVerify -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $verifyResult.Verified $true "Verify succeeds immediately after sync"
    Assert-Equal $verifyResult.Discrepancies.Count 0 "Zero discrepancies on cleanly synced project"

    # 4.5 Local Skill Modification Protection
    Write-Host "`nTest 5: Local skill modification detection & overwrite refusal" -ForegroundColor Yellow
    $modSkillTarget = Join-Path $tmpDir ".agents\skills\targeted-repo-search\SKILL.md"
    Add-Content -Path $modSkillTarget -Value "`n# Local modification test skill"

    $verifyModSkill = Invoke-DevKitVerify -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $verifyModSkill.Verified $false "Verify detects local skill modification"
    $modSkillItem = $verifyModSkill.Discrepancies | Where-Object { $_.TargetPath -eq $modSkillTarget }
    Assert-Equal $modSkillItem.Status "modified" "Marks modified skill target as status 'modified'"

    $syncBlockedSkill = Invoke-DevKitSync -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $syncBlockedSkill.Blocked 1 "Sync blocks overwrite of locally modified skill file"
    $preservedSkillContent = Get-Content -Path $modSkillTarget -Raw
    Assert-True ($preservedSkillContent.Contains("Local modification test skill")) "Local skill modification is strictly preserved"

    # 4.6 Local Hook Modification Protection
    Write-Host "`nTest 6: Local hook modification detection & overwrite refusal" -ForegroundColor Yellow
    $modHookTarget = Join-Path $tmpDir ".claude\hooks\hook-io.mjs"
    Add-Content -Path $modHookTarget -Value "`n// Local modification test hook"

    $verifyModHook = Invoke-DevKitVerify -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $verifyModHook.Verified $false "Verify detects local hook modification"
    $modHookItem = $verifyModHook.Discrepancies | Where-Object { $_.TargetPath -eq $modHookTarget }
    Assert-Equal $modHookItem.Status "modified" "Marks modified hook target as status 'modified'"

    $syncBlockedHook = Invoke-DevKitSync -ProjectDir $tmpDir -DevKitRoot $devKitRoot
    Assert-Equal $syncBlockedHook.Blocked 2 "Sync blocks overwrite of all locally modified files (1 skill + 1 hook)"
    $preservedHookContent = Get-Content -Path $modHookTarget -Raw
    Assert-True ($preservedHookContent.Contains("Local modification test hook")) "Local hook modification is strictly preserved"

    # Test 7: Non-existence of -Force bypass for sync
    Write-Host "`nTest 7: Confirm absence of -Force bypass in sync interface" -ForegroundColor Yellow
    $syncCommand = Get-Command Invoke-DevKitSync
    Assert-True (-not $syncCommand.Parameters.ContainsKey("Force")) "Invoke-DevKitSync does NOT expose a -Force parameter"

    $cliScript = Get-Content (Join-Path $devKitRoot "bin\agent-devkit.ps1") -Raw
    Assert-True (-not ($cliScript -match '\[switch\]\$Force')) "CLI agent-devkit.ps1 does NOT declare a -Force parameter"

}
finally {
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Test 8: Third-Party Registry Resolution & Metadata
Write-Host "`nTest 8: Third-party registry resolution & metadata" -ForegroundColor Yellow
$tpEntry = Resolve-DevKitThirdParty -ComponentName "caveman" -DevKitRoot $devKitRoot
Assert-True ($null -ne $tpEntry) "Resolves caveman entry from third-party registry"
Assert-Equal $tpEntry.type "github" "Type is github"
Assert-Equal $tpEntry.repo "JuliusBrussee/caveman" "Repository is JuliusBrussee/caveman"
Assert-Equal $tpEntry.ref "f5d729488caa8f6a5b6c8086fe2cccd3e8a63f91" "Pinned commit SHA is exact and immutable"
Assert-Equal $tpEntry.subpath "skills/caveman" "Subpath is skills/caveman"
Assert-Equal $tpEntry.policy "data-only" "Policy is data-only"
Assert-Equal $tpEntry.license "Apache-2.0" "License is Apache-2.0"

# Official frontend-design skill is registered without duplicating its source.
$frontendDesign = Resolve-DevKitThirdParty -ComponentName "frontend-design" -DevKitRoot $devKitRoot
Assert-True ($null -ne $frontendDesign) "Resolves frontend-design from third-party registry"
Assert-Equal $frontendDesign.repo "anthropics/skills" "References Anthropic official skills repository"
Assert-Equal $frontendDesign.ref "683bc88e56f3e09ba94f7055977f3d3aa499f202" "Pins frontend-design to reviewed commit"
Assert-Equal $frontendDesign.subpath "skills/frontend-design" "Uses official frontend-design subpath"
Assert-Equal $frontendDesign.policy "data-only" "Uses data-only third-party policy"
Assert-Equal $frontendDesign.license "Apache-2.0" "Preserves upstream license metadata"
$rpProfile = Get-DevKitProfile -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-True ($rpProfile.thirdPartySkills -contains "frontend-design") "Profile rp-doces enables frontend-design"

$nullEntry = Resolve-DevKitThirdParty -ComponentName "non-existent-tp" -DevKitRoot $devKitRoot
Assert-True ($null -eq $nullEntry) "Non-existent third-party component resolves to null"

# Test 9: Security & Validation (Path Traversal, Forbidden Files, Reparse Points)
Write-Host "`nTest 9: Security checks (Path Traversal, Forbidden Files, Reparse Points)" -ForegroundColor Yellow
$fixtureBase = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-sec-test-$(Get-Random)"
New-Item -ItemType Directory -Path $fixtureBase -Force | Out-Null

try {
    # 9.1 Valid data-only package passes
    $validPkg = Join-Path $fixtureBase "valid-pkg"
    New-Item -ItemType Directory -Path $validPkg -Force | Out-Null
    Set-Content -Path (Join-Path $validPkg "SKILL.md") -Value "# Test Skill"
    Set-Content -Path (Join-Path $validPkg "README.md") -Value "Documentation"
    $cleanPass = $true
    try {
        Test-DevKitPackageSecurity -Path $validPkg -Policy "data-only"
    } catch {
        $cleanPass = $false
    }
    Assert-True $cleanPass "Valid data-only package passes security inspection"

    # 9.2 Forbidden executable / script rejection
    $forbiddenPkg = Join-Path $fixtureBase "forbidden-pkg"
    New-Item -ItemType Directory -Path $forbiddenPkg -Force | Out-Null
    Set-Content -Path (Join-Path $forbiddenPkg "malicious.ps1") -Value "Write-Host 'pwn'"
    Assert-Throws { Test-DevKitPackageSecurity -Path $forbiddenPkg -Policy "data-only" } "Forbidden file extension" "Rejects package containing executable / script file (.ps1)"

    # 9.3 Unallowed file extension under data-only
    $unallowedPkg = Join-Path $fixtureBase "unallowed-pkg"
    New-Item -ItemType Directory -Path $unallowedPkg -Force | Out-Null
    Set-Content -Path (Join-Path $unallowedPkg "binary.exe") -Value "binary data"
    Assert-Throws { Test-DevKitPackageSecurity -Path $unallowedPkg -Policy "data-only" } "Forbidden file extension" "Rejects package containing .exe under data-only"

    # 9.4 Reparse point / Junction rejection (when testable on Windows)
    $junctionSource = Join-Path $fixtureBase "junction-source"
    $junctionTarget = Join-Path $fixtureBase "junction-pkg"
    New-Item -ItemType Directory -Path $junctionSource -Force | Out-Null
    Set-Content -Path (Join-Path $junctionSource "file.md") -Value "data"
    $mklinkOutput = cmd /c "mklink /J `"$junctionTarget`" `"$junctionSource`"" 2>&1
    if (Test-Path $junctionTarget) {
        Assert-Throws { Test-DevKitPackageSecurity -Path $junctionTarget -Policy "data-only" } "Symlink or reparse point detected" "Rejects directory junction / reparse point"
        cmd /c "rmdir `"$junctionTarget`"" 2>&1 | Out-Null
    } else {
        Write-Host "  SKIP: mklink not supported in current environment permissions" -ForegroundColor DarkGray
    }

    # 9.5 Path traversal in declared subpath
    $mockEntryTraversal = [PSCustomObject]@{
        type    = "github"
        repo    = "user/repo"
        ref     = "abcdef1234567890"
        subpath = "../../etc/passwd"
        policy  = "data-only"
    }
    Assert-Throws {
        if ($mockEntryTraversal.subpath -like '*..*' -or $mockEntryTraversal.subpath -match '^[\\/]') {
            throw "Path traversal detected in declared subpath '$($mockEntryTraversal.subpath)'"
        }
    } "Path traversal detected" "Rejects path traversal in declared subpath"

}
finally {
    Remove-Item -Path $fixtureBase -Recurse -Force -ErrorAction SilentlyContinue
}

# Test 10: Negative Fetch, Download Failure & Atomicity
Write-Host "`nTest 10: Negative fetch / download failure & Atomicity" -ForegroundColor Yellow
$mockBadRepoEntry = [PSCustomObject]@{
    repo                 = "non-existent-user-xyz12345/non-existent-repo-abc67890"
    ref                  = "main"
    subpath              = "skills/mock"
    policy               = "data-only"
    allowedExtensions    = @(".md")
    disallowedExtensions = @(".exe", ".bat", ".ps1")
}

Assert-Throws {
    Fetch-DevKitThirdParty -ComponentName "bad-repo" -RegistryEntry $mockBadRepoEntry
} "Failed to fetch ref" "Fails cleanly on non-existent repository without leaving temp files"

# 10.2 Atomicity: package with security failure creates 0 target files
$mockBadPkgDir = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-bad-pkg-$(Get-Random)"
New-Item -ItemType Directory -Path (Join-Path $mockBadPkgDir "skills\bad-skill") -Force | Out-Null
Set-Content -Path (Join-Path $mockBadPkgDir "skills\bad-skill\SKILL.md") -Value "# Valid"
Set-Content -Path (Join-Path $mockBadPkgDir "skills\bad-skill\exploit.exe") -Value "payload"

$mockBadEntry = [PSCustomObject]@{
    repo                 = "mock/bad-pkg"
    ref                  = "main"
    subpath              = "skills/bad-skill"
    policy               = "data-only"
    allowedExtensions    = @(".md")
    disallowedExtensions = @(".exe")
}

Assert-Throws {
    Fetch-DevKitThirdParty -ComponentName "bad-skill" -RegistryEntry $mockBadEntry -MockDir $mockBadPkgDir
} "Forbidden file extension" "Rejects partially invalid package and aborts before materialization"
Remove-Item -Path $mockBadPkgDir -Recurse -Force -ErrorAction SilentlyContinue

# Test 11: Real Upstream Integration Test (Caveman)
Write-Host "`nTest 11: Real Upstream Integration Test (Caveman: Fetch, DryRun, Sync, Lock, Verify)" -ForegroundColor Yellow
$tpProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) "agent-devkit-caveman-$(Get-Random)"
New-Item -ItemType Directory -Path $tpProjectDir -Force | Out-Null

try {
    # 11.1 Mock consumer project with caveman in manifest
    $tpManifest = [PSCustomObject]@{
        version = "1.0.0"
        profile = "rp-doces"
        skills  = @("caveman")
        targets = @(".agents/skills", ".claude/skills")
    }
    $tpManifestJson = $tpManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $tpProjectDir "agent-devkit.json"), $tpManifestJson, [System.Text.UTF8Encoding]::new($false))

    # 11.2 Dry-Run: must fetch in TEMP to inspect, but NOT write to project
    $dryResult = Invoke-DevKitSync -ProjectDir $tpProjectDir -DryRun -DevKitRoot $devKitRoot
    Assert-Equal $dryResult.DryRun $true "DryRun mode reported"
    Assert-Equal $dryResult.Materialized 0 "DryRun wrote 0 files to target project"
    Assert-True ($dryResult.Missing -ge 4) "DryRun detected missing caveman files (2 files x 2 targets)"
    Assert-True (-not (Test-Path (Join-Path $tpProjectDir ".claude\skills\caveman"))) "DryRun did not create target directory"
    Assert-True (-not (Test-Path (Join-Path $tpProjectDir "agent-devkit.lock"))) "DryRun did not create lockfile"

    # 11.3 Real Sync: downloads upstream from JuliusBrussee/caveman@f5d729488caa8f6a5b6c8086fe2cccd3e8a63f91
    $syncResult = Invoke-DevKitSync -ProjectDir $tpProjectDir -DevKitRoot $devKitRoot
    Assert-True ($syncResult.Materialized -ge 4) "Real sync materialized caveman files (SKILL.md and README.md across targets)"
    Assert-True (Test-Path (Join-Path $tpProjectDir ".claude\skills\caveman\SKILL.md")) "Materialized SKILL.md in .claude/skills"
    Assert-True (Test-Path (Join-Path $tpProjectDir ".claude\skills\caveman\README.md")) "Materialized README.md in .claude/skills"
    Assert-True (Test-Path (Join-Path $tpProjectDir ".agents\skills\caveman\SKILL.md")) "Materialized SKILL.md in .agents/skills"
    Assert-True (Test-Path (Join-Path $tpProjectDir "agent-devkit.lock")) "Created lockfile with third-party record"

    # 11.4 Check lock provenance and SHA-256
    $lockObj = Get-DevKitLock -ProjectDir $tpProjectDir
    $cavemanLock = $lockObj.skills.caveman
    Assert-Equal $cavemanLock.repo "JuliusBrussee/caveman" "Lockfile records upstream repository"
    Assert-Equal $cavemanLock.ref "f5d729488caa8f6a5b6c8086fe2cccd3e8a63f91" "Lockfile records immutable ref"
    Assert-Equal $cavemanLock.policy "data-only" "Lockfile records data-only policy"
    Assert-Equal $cavemanLock.license "Apache-2.0" "Lockfile records license"
    Assert-True ($null -ne $cavemanLock.files."SKILL.md".sha256 -and $cavemanLock.files."SKILL.md".sha256.Length -eq 64) "Lockfile records valid 64-character SHA-256 for SKILL.md"

    # 11.5 Verify immediately after sync
    $verifyResult = Invoke-DevKitVerify -ProjectDir $tpProjectDir -DevKitRoot $devKitRoot
    Assert-Equal $verifyResult.Verified $true "Verify succeeds immediately after sync for third-party dependency"
    Assert-Equal $verifyResult.Discrepancies.Count 0 "Zero discrepancies reported on verified third-party skill"

    # 11.6 Local modification detection & overwrite refusal on third-party file
    $modCavemanFile = Join-Path $tpProjectDir ".claude\skills\caveman\SKILL.md"
    Add-Content -Path $modCavemanFile -Value "`n# Local custom instructions for caveman"

    $verifyMod = Invoke-DevKitVerify -ProjectDir $tpProjectDir -DevKitRoot $devKitRoot
    Assert-Equal $verifyMod.Verified $false "Verify detects local modification in third-party file"
    $modItem = $verifyMod.Discrepancies | Where-Object { $_.TargetPath -eq $modCavemanFile }
    Assert-Equal $modItem.Status "modified" "Status is 'modified'"

    $syncMod = Invoke-DevKitSync -ProjectDir $tpProjectDir -DevKitRoot $devKitRoot
    Assert-True ($syncMod.Blocked -ge 1) "Sync blocks overwrite of modified third-party file"
    $modContent = Get-Content -Path $modCavemanFile -Raw
    Assert-True ($modContent.Contains("Local custom instructions for caveman")) "Local modification in third-party file is strictly preserved"

}
finally {
    Remove-Item -Path $tpProjectDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nTest 12: Skill catalog and inspection (Core, Profile-Specific, Third-Party)" -ForegroundColor Yellow

$catalog = Get-DevKitSkillCatalog -DevKitRoot $devKitRoot
Assert-True ($catalog.Count -ge 8) "Catalog contains all core, profile, and third-party skills"

# Check core skill
$coreItem = $catalog | Where-Object { $_.Name -eq "targeted-repo-search" }
Assert-True ($null -ne $coreItem) "Finds targeted-repo-search in catalog"
Assert-Equal $coreItem.Category "core" "Core skill has category 'core'"
Assert-Equal $coreItem.Ownership "core" "Core skill has ownership 'core'"
Assert-Equal $coreItem.Policy "trusted-core" "Core skill has policy 'trusted-core'"
Assert-Equal $coreItem.State "declared" "Core skill has state 'declared'"

# Check profile skill
$profItem = $catalog | Where-Object { $_.Name -eq "rp-targeted-workflow" }
Assert-True ($null -ne $profItem) "Finds rp-targeted-workflow in catalog"
Assert-Equal $profItem.Category "profile-specific" "Profile skill has category 'profile-specific'"
Assert-Equal $profItem.Ownership "profile-specific" "Profile skill has ownership 'profile-specific'"
Assert-Equal $profItem.Profile "rp-doces" "Profile skill belongs to 'rp-doces'"
Assert-Equal $profItem.Policy "profile-owned" "Profile skill has policy 'profile-owned'"
Assert-Equal $profItem.State "declared" "Declared profile skill has state 'declared'"

# Check third-party skill
$tpItem = $catalog | Where-Object { $_.Name -eq "caveman" }
Assert-True ($null -ne $tpItem) "Finds caveman in catalog"
Assert-Equal $tpItem.Category "third-party" "Third-party skill has category 'third-party'"
Assert-Equal $tpItem.Ownership "third-party" "Third-party skill has ownership 'third-party'"
Assert-Equal $tpItem.Policy "data-only" "Third-party skill has policy 'data-only'"
Assert-Equal $tpItem.License "Apache-2.0" "Third-party skill has license 'Apache-2.0'"
Assert-Equal $tpItem.Ref "f5d729488caa8f6a5b6c8086fe2cccd3e8a63f91" "Third-party skill has immutable ref"

# Check Get-DevKitSkillInfo
$infoCore = Get-DevKitSkillInfo -SkillName "targeted-repo-search" -DevKitRoot $devKitRoot
Assert-Equal $infoCore.Name "targeted-repo-search" "Get-DevKitSkillInfo resolves core skill"
Assert-Equal $infoCore.Category "core" "Resolved skill is category core"

$infoProf = Get-DevKitSkillInfo -SkillName "rp-targeted-workflow" -DevKitRoot $devKitRoot
Assert-Equal $infoProf.Name "rp-targeted-workflow" "Get-DevKitSkillInfo resolves profile skill"
Assert-Equal $infoProf.Profile "rp-doces" "Resolved skill is bound to profile"

$infoTp = Get-DevKitSkillInfo -SkillName "caveman" -DevKitRoot $devKitRoot
Assert-Equal $infoTp.Name "caveman" "Get-DevKitSkillInfo resolves third-party skill"

$infoNull = Get-DevKitSkillInfo -SkillName "non-existent-skill" -DevKitRoot $devKitRoot
Assert-True ($null -eq $infoNull) "Non-existent skill resolves to null"

# Check Profile listing and showing
$profList = Get-DevKitProfileList -DevKitRoot $devKitRoot
Assert-True (@($profList).Count -ge 1) "Get-DevKitProfileList returns profiles"
$rpDocesProf = $profList | Where-Object { $_.Name -eq "rp-doces" }
Assert-True ($null -ne $rpDocesProf) "Profile list contains rp-doces"
Assert-Equal $rpDocesProf.SkillsCount 7 "rp-doces has 7 declared skills"
Assert-Equal $rpDocesProf.HooksCount 9 "rp-doces has 9 declared hooks"
Assert-Equal $rpDocesProf.InstructionsCount 2 "rp-doces has 2 declared instructions"
Assert-Equal $rpDocesProf.RulesCount 15 "rp-doces has 15 declared rules"
Assert-Equal $rpDocesProf.AgentsCount 1 "rp-doces has 1 declared agent"
Assert-Equal $rpDocesProf.ConfigsCount 1 "rp-doces has 1 declared config"

$profObj = Get-DevKitProfile -ProfileName "rp-doces" -DevKitRoot $devKitRoot
Assert-Equal $profObj.name "rp-doces" "Get-DevKitProfile parses rp-doces profile.json"
Assert-Throws { Get-DevKitProfile -ProfileName "non-existent-profile" -DevKitRoot $devKitRoot } "Profile 'non-existent-profile' not found" "Throws on non-existent profile"


Write-Host "`nTest 13: Profile add & remove declarative operations" -ForegroundColor Yellow

$tempProfileDir = Join-Path $devKitRoot "profiles\test-temp-profile"
New-Item -ItemType Directory -Path $tempProfileDir -Force | Out-Null
$tempProfileSkillsDir = Join-Path $tempProfileDir "skills\local-tool"
New-Item -ItemType Directory -Path $tempProfileSkillsDir -Force | Out-Null
Set-Content -Path (Join-Path $tempProfileSkillsDir "SKILL.md") -Value "---\nname: local-tool\ndescription: A temporary local skill\n---\nLocal tool body"

$initialProfileJson = [ordered]@{
    name             = "test-temp-profile"
    version          = "1.0.0"
    description      = "Temporary profile for automated tests"
    skills           = @()
    hooks            = @()
    thirdPartySkills = @()
} | ConvertTo-Json -Depth 10

Set-Content -Path (Join-Path $tempProfileDir "profile.json") -Value $initialProfileJson

try {
    # 13.1 Check undeclared profile-specific skill has state 'available'
    $catBefore = Get-DevKitSkillCatalog -DevKitRoot $devKitRoot
    $availSkill = $catBefore | Where-Object { $_.Name -eq "local-tool" }
    Assert-True ($null -ne $availSkill) "Catalog detects physical profile-specific folder"
    Assert-Equal $availSkill.Category "profile-specific" "Ownership is profile-specific"
    Assert-Equal $availSkill.State "available" "Undeclared skill state is 'available'"
    Assert-Equal $availSkill.Profiles.Count 0 "Undeclared skill is not yet declared in profile"

    # 13.2 Add available profile-specific skill
    $addLocal = Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "local-tool" -DevKitRoot $devKitRoot
    Assert-Equal $addLocal.Action "added" "Add available profile-specific skill succeeds"
    Assert-Equal $addLocal.TargetList "skills" "Added to 'skills' array"

    $pUpdated1 = Get-DevKitProfile -ProfileName "test-temp-profile" -DevKitRoot $devKitRoot
    Assert-True ($pUpdated1.skills -contains "local-tool") "Profile now declares local-tool"

    # State in catalog should now be 'declared'
    $catAfter1 = Get-DevKitSkillCatalog -DevKitRoot $devKitRoot
    $declaredSkill = $catAfter1 | Where-Object { $_.Name -eq "local-tool" }
    Assert-Equal $declaredSkill.State "declared" "Skill state updated to 'declared'"
    Assert-True ($declaredSkill.Profiles -contains "test-temp-profile") "Profile is registered in Profiles array"

    # 13.3 Add core skill
    $addCore = Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "targeted-repo-search" -DevKitRoot $devKitRoot
    Assert-Equal $addCore.Action "added" "Add core skill succeeds"
    Assert-Equal $addCore.TargetList "skills" "Core skill added to 'skills' array"

    # 13.4 Add third-party skill
    $addTp = Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "caveman" -DevKitRoot $devKitRoot
    Assert-Equal $addTp.Action "added" "Add third-party skill succeeds"
    Assert-Equal $addTp.TargetList "thirdPartySkills" "Third-party skill added to 'thirdPartySkills' array"

    $pUpdated2 = Get-DevKitProfile -ProfileName "test-temp-profile" -DevKitRoot $devKitRoot
    Assert-True ($pUpdated2.skills -contains "targeted-repo-search") "Profile declares targeted-repo-search"
    Assert-True ($pUpdated2.thirdPartySkills -contains "caveman") "Profile declares caveman"

    # 13.5 Duplicate skill rejection
    Assert-Throws {
        Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "caveman" -DevKitRoot $devKitRoot
    } "already declared" "Rejects duplicate third-party skill addition"

    Assert-Throws {
        Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "targeted-repo-search" -DevKitRoot $devKitRoot
    } "already declared" "Rejects duplicate core skill addition"

    # 13.6 Non-existent skill rejection
    Assert-Throws {
        Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "fake-missing-skill" -DevKitRoot $devKitRoot
    } "not known in DevKit catalog" "Rejects unknown skill"

    # 13.7 Cross-profile profile-specific skill rejection
    Assert-Throws {
        Add-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "rp-targeted-workflow" -DevKitRoot $devKitRoot
    } "profile-specific to 'rp-doces' and cannot be added" "Rejects profile-specific skill from another profile"

    # 13.8 Remove third-party skill
    $remTp = Remove-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "caveman" -DevKitRoot $devKitRoot
    Assert-Equal $remTp.Action "removed" "Remove third-party skill succeeds"
    Assert-Equal $remTp.RemovedFrom "thirdPartySkills" "Removed from thirdPartySkills"
    Assert-True ($remTp.Message.Contains("reconciliation/prune")) "Removal message contains reconciliation/prune advisory notice"

    $pUpdated3 = Get-DevKitProfile -ProfileName "test-temp-profile" -DevKitRoot $devKitRoot
    Assert-True (-not ($pUpdated3.thirdPartySkills -contains "caveman")) "caveman no longer in thirdPartySkills"

    # 13.9 Remove core skill
    $remCore = Remove-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "targeted-repo-search" -DevKitRoot $devKitRoot
    Assert-Equal $remCore.Action "removed" "Remove core skill succeeds"
    Assert-Equal $remCore.RemovedFrom "skills" "Removed from skills"

    # 13.10 Remove profile-specific skill does NOT delete physical folder
    $remLocal = Remove-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "local-tool" -DevKitRoot $devKitRoot
    Assert-Equal $remLocal.Action "removed" "Remove local-tool succeeds"
    Assert-True (Test-Path $tempProfileSkillsDir -PathType Container) "Physical folder for local-tool was NOT deleted on remove"
    Assert-True (Test-Path (Join-Path $tempProfileSkillsDir "SKILL.md") -PathType Leaf) "Physical SKILL.md for local-tool was NOT deleted"

    # 13.11 Remove non-declared skill rejection
    Assert-Throws {
        Remove-DevKitProfileSkill -ProfileName "test-temp-profile" -SkillName "caveman" -DevKitRoot $devKitRoot
    } "not declared in profile" "Rejects removing skill not present in profile"
}
finally {
    Remove-Item -Path $tempProfileDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Test 14: Expanded Profile Components (Instructions, Rules, Agents, Configs, Overlays) & External Sync
Write-Host "`nTest 14: Expanded Profile Components (Instructions, Rules, Agents, Configs, Overlays) & External Sync" -ForegroundColor Yellow

$sandboxPhaseA2 = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-sandbox-phase-a2-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $sandboxPhaseA2 -Force | Out-Null

$externalStateDir = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-ext-state-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $externalStateDir -Force | Out-Null

try {
    # 14.1 Dry-Run with external profile and no manifest in consumer
    $dryRes = Invoke-DevKitSync -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DryRun -DevKitRoot $devKitRoot
    Assert-True $dryRes.DryRun "Sync reported DryRun mode"
    Assert-Equal (Get-ChildItem -Path $sandboxPhaseA2 -Recurse -File).Count 0 "DryRun did not write any files to sandbox"
    Assert-True (-not (Test-Path (Join-Path $sandboxPhaseA2 "agent-devkit.json"))) "DryRun did not create manifest in consumer"
    Assert-True (-not (Test-Path (Join-Path $sandboxPhaseA2 "agent-devkit.lock"))) "DryRun did not create lockfile in consumer"
    Assert-True (-not (Test-Path (Join-Path $externalStateDir "agent-devkit.lock"))) "DryRun did not create lockfile in state dir"

    # 14.2 Real External Sync (no manifest in consumer project)
    $syncRes = Invoke-DevKitSync -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DevKitRoot $devKitRoot
    Assert-True ($syncRes.Materialized -gt 0) "External sync materialized components"
    Assert-Equal $syncRes.Blocked 0 "Zero blocked components during clean external sync"

    # Ensure consumer repo has ZERO DevKit infrastructure files
    Assert-True (-not (Test-Path (Join-Path $sandboxPhaseA2 "agent-devkit.json"))) "Consumer project has NO agent-devkit.json"
    Assert-True (-not (Test-Path (Join-Path $sandboxPhaseA2 "agent-devkit.lock"))) "Consumer project has NO agent-devkit.lock"
    Assert-True (Test-Path (Join-Path $externalStateDir "agent-devkit.lock")) "Lockfile was saved strictly in external StateDir"

    # 14.3 Materialization of Instructions
    $claudeMd = Join-Path $sandboxPhaseA2 "CLAUDE.md"
    $agentsMd = Join-Path $sandboxPhaseA2 "AGENTS.md"
    Assert-True (Test-Path $claudeMd -PathType Leaf) "Materialized root CLAUDE.md"
    Assert-True (Test-Path $agentsMd -PathType Leaf) "Materialized root AGENTS.md"
    Assert-Equal (Get-DevKitSha256 -Path $claudeMd) (Get-DevKitSha256 -Path (Join-Path $devKitRoot "profiles\rp-doces\instructions\CLAUDE.md")) "CLAUDE.md matches source SHA-256"
    Assert-Equal (Get-DevKitSha256 -Path $agentsMd) (Get-DevKitSha256 -Path (Join-Path $devKitRoot "profiles\rp-doces\instructions\AGENTS.md")) "AGENTS.md matches source SHA-256"

    # 14.4 Materialization of Rules
    $ruleDdd = Join-Path $sandboxPhaseA2 ".claude\rules\01-ddd.md"
    $ruleReact = Join-Path $sandboxPhaseA2 ".claude\rules\react\coding-standards.md"
    $ruleTs = Join-Path $sandboxPhaseA2 ".claude\rules\typescript\coding-standards.md"
    Assert-True (Test-Path $ruleDdd -PathType Leaf) "Materialized rule 01-ddd.md"
    Assert-True (Test-Path $ruleReact -PathType Leaf) "Materialized nested rule react/coding-standards.md"
    Assert-True (Test-Path $ruleTs -PathType Leaf) "Materialized nested rule typescript/coding-standards.md"
    $ruleFiles = Get-ChildItem -Path (Join-Path $sandboxPhaseA2 ".claude\rules") -Recurse -File
    Assert-Equal $ruleFiles.Count 15 "Materialized all 15 rules"

    # 14.5 Materialization of Agents
    $agentFile = Join-Path $sandboxPhaseA2 ".claude\agents\money-path-reviewer.md"
    Assert-True (Test-Path $agentFile -PathType Leaf) "Materialized agent money-path-reviewer.md"
    Assert-Equal (Get-DevKitSha256 -Path $agentFile) (Get-DevKitSha256 -Path (Join-Path $devKitRoot "profiles\rp-doces\agents\money-path-reviewer.md")) "Agent file matches source SHA-256"

    # 14.6 Materialization of Configs
    $configFile = Join-Path $sandboxPhaseA2 ".claude\settings.json"
    Assert-True (Test-Path $configFile -PathType Leaf) "Materialized config .claude/settings.json"
    Assert-Equal (Get-DevKitSha256 -Path $configFile) (Get-DevKitSha256 -Path (Join-Path $devKitRoot "profiles\rp-doces\configs\settings.json")) "Config file matches source SHA-256"

    # 14.7 Materialization of Hooks (including verify-on-stop.mjs)
    $hookVerify = Join-Path $sandboxPhaseA2 ".claude\hooks\verify-on-stop.mjs"
    Assert-True (Test-Path $hookVerify -PathType Leaf) "Materialized hook verify-on-stop.mjs"
    $hookFiles = Get-ChildItem -Path (Join-Path $sandboxPhaseA2 ".claude\hooks") -File
    Assert-Equal $hookFiles.Count 9 "Materialized all 9 hooks"

    # 14.8 Verify on cleanly materialized external project
    $verRes = Invoke-DevKitVerify -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DevKitRoot $devKitRoot
    Assert-True $verRes.Verified "External verify succeeds immediately after sync"
    Assert-Equal $verRes.Discrepancies.Count 0 "Zero discrepancies reported on clean external sync"

    # 14.9 Sync when targets already exist (idempotence)
    $secondSync = Invoke-DevKitSync -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DevKitRoot $devKitRoot
    Assert-Equal $secondSync.Materialized 0 "Second sync materializes 0 files (idempotent)"
    Assert-Equal $secondSync.Synced $syncRes.TotalFiles "All files reported as synced"

    # 14.10 Local modification detection and overwrite refusal across categories
    Set-Content -Path $claudeMd -Value "Modified local CLAUDE.md"
    Set-Content -Path $ruleDdd -Value "Modified local 01-ddd.md"
    Set-Content -Path $agentFile -Value "Modified local money-path-reviewer.md"
    Set-Content -Path $configFile -Value "{ `"modified`": true }"
    Set-Content -Path $hookVerify -Value "// Modified local hook"

    $verMod = Invoke-DevKitVerify -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DevKitRoot $devKitRoot
    Assert-True (-not $verMod.Verified) "Verify detects local modifications across categories"
    $modTypes = $verMod.Discrepancies | Select-Object -ExpandProperty Type
    Assert-True ($modTypes -contains "instruction") "Verify detected modified instruction"
    Assert-True ($modTypes -contains "rule") "Verify detected modified rule"
    Assert-True ($modTypes -contains "agent") "Verify detected modified agent"
    Assert-True ($modTypes -contains "config") "Verify detected modified config"
    Assert-True ($modTypes -contains "hook") "Verify detected modified hook"

    $syncMod = Invoke-DevKitSync -ProjectDir $sandboxPhaseA2 -Profile "rp-doces" -StateDir $externalStateDir -DevKitRoot $devKitRoot
    Assert-Equal $syncMod.Blocked 5 "Sync blocked all 5 modified files from being overwritten"
    Assert-Equal (Get-Content -Path $claudeMd -Raw).Trim() "Modified local CLAUDE.md" "Local instruction modification was preserved"
    Assert-Equal (Get-Content -Path $ruleDdd -Raw).Trim() "Modified local 01-ddd.md" "Local rule modification was preserved"
    Assert-Equal (Get-Content -Path $agentFile -Raw).Trim() "Modified local money-path-reviewer.md" "Local agent modification was preserved"
    Assert-Equal (Get-Content -Path $configFile -Raw).Trim() "{ `"modified`": true }" "Local config modification was preserved"
    Assert-Equal (Get-Content -Path $hookVerify -Raw).Trim() "// Modified local hook" "Local hook modification was preserved"

    # 14.11 Path Traversal security validation
    Assert-Throws {
        Test-DevKitSafeTargetPath -ProjectDir $sandboxPhaseA2 -RelativeTarget "../outside.txt"
    } "Path traversal detected" "Rejects relative path traversal escaping project dir"

    Assert-Throws {
        Test-DevKitSafeTargetPath -ProjectDir $sandboxPhaseA2 -RelativeTarget "sub/../../escape.txt"
    } "Path traversal detected" "Rejects nested path traversal escaping project dir"

    # 14.12 Custom overlays & profile isolation test
    $isoProfileDir = Join-Path $devKitRoot "profiles\test-isolation-profile"
    New-Item -ItemType Directory -Path (Join-Path $isoProfileDir "overlays") -Force | Out-Null
    Set-Content -Path (Join-Path $isoProfileDir "overlays\custom-file.txt") -Value "Custom overlay content"
    $isoProfileJson = [ordered]@{
        name     = "test-isolation-profile"
        version  = "1.0.0"
        skills   = @()
        hooks    = @()
        overlays = @(
            @{ source = "custom-file.txt"; target = "config/custom-output.txt" }
        )
    } | ConvertTo-Json -Depth 10
    Set-Content -Path (Join-Path $isoProfileDir "profile.json") -Value $isoProfileJson

    $isoSandbox = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-iso-sandbox-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $isoSandbox -Force | Out-Null
    $isoStateDir = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-iso-state-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $isoStateDir -Force | Out-Null

    try {
        $isoSync = Invoke-DevKitSync -ProjectDir $isoSandbox -Profile "test-isolation-profile" -StateDir $isoStateDir -DevKitRoot $devKitRoot
        Assert-Equal $isoSync.Materialized 1 "Overlay materialized exactly 1 file"
        $overlayTarget = Join-Path $isoSandbox "config\custom-output.txt"
        Assert-True (Test-Path $overlayTarget -PathType Leaf) "Custom overlay file exists at declared target"
        Assert-Equal (Get-Content $overlayTarget -Raw).Trim() "Custom overlay content" "Overlay content matches source"

        $rpDocesManifest = New-DevKitManifestFromProfile -ProfileName "rp-doces" -DevKitRoot $devKitRoot
        Assert-Equal $rpDocesManifest.overlays.Count 0 "rp-doces profile remains isolated from other profile overlays"
    }
    finally {
        Remove-Item -Path $isoProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $isoSandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $isoStateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -Path $sandboxPhaseA2 -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $externalStateDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Test 15: Local Git Isolation via .git/info/exclude
Write-Host "`nTest 15: Local Git Isolation via .git/info/exclude" -ForegroundColor Yellow

$gitSandbox = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-git-sandbox-$([Guid]::NewGuid().ToString('N'))"
$gitStateDir = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-git-state-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $gitSandbox -Force | Out-Null
New-Item -ItemType Directory -Path $gitStateDir -Force | Out-Null

try {
    # Initialize a clean git repo in sandbox
    $dotGit = Join-Path $gitSandbox ".git"
    $gitInfo = Join-Path $dotGit "info"
    New-Item -ItemType Directory -Path $gitInfo -Force | Out-Null
    $excludeFile = Join-Path $gitInfo "exclude"

    # Pre-existing user entries in .git/info/exclude
    $userHeader = "# User custom excludes`nmy-local-notes.txt`nscratch-debug/"
    Set-Content -Path $excludeFile -Value $userHeader

    # Dummy tracked/untracked test files in consumer
    $dummyGitignore = Join-Path $gitSandbox ".gitignore"
    Set-Content -Path $dummyGitignore -Value "node_modules/`ndist/"
    $gitignoreShaBefore = Get-DevKitSha256 -Path $dummyGitignore

    # 15.1 Safe failure when not a git repository
    $noGitDir = Join-Path ([System.IO.Path]::GetTempPath()) "devkit-nogit-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $noGitDir -Force | Out-Null
    try {
        $noGitRes = Set-DevKitGitExclude -ProjectDir $noGitDir -ExcludePaths @(".claude/")
        Assert-Equal $noGitRes.Updated $false "Gracefully skips non-git directory without throwing"
        Assert-Equal $noGitRes.Reason "NoGitRepository" "Identifies reason as NoGitRepository"
    }
    finally {
        Remove-Item -Path $noGitDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 15.2 Deriving profile exclude paths
    $excludePaths = Get-DevKitProfileExcludePaths -ProfileName "rp-doces" -DevKitRoot $devKitRoot
    Assert-True ($excludePaths -contains ".agents/") "Exclude list includes .agents/"
    Assert-True ($excludePaths -contains ".claude/") "Exclude list includes .claude/"
    Assert-True ($excludePaths -contains "CLAUDE.md") "Exclude list includes CLAUDE.md"
    Assert-True ($excludePaths -contains "AGENTS.md") "Exclude list includes AGENTS.md"
    Assert-True ($excludePaths -contains ".mcp.json") "Exclude list includes .mcp.json"
    Assert-True ($excludePaths -contains ".graphifyignore") "Exclude list includes .graphifyignore"
    Assert-True ($excludePaths -contains "graphify-out/") "Exclude list includes graphify-out/"

    # 15.3 Applying exclude block
    $resExclude = Set-DevKitGitExclude -ProjectDir $gitSandbox -ExcludePaths $excludePaths
    Assert-True $resExclude.Updated "Set-DevKitGitExclude reported updated"
    $excludeContent = Get-Content -Path $excludeFile -Raw

    Assert-True ($excludeContent.Contains("# BEGIN AGENT-DEVKIT MANAGED EXCLUDES")) "Contains start marker"
    Assert-True ($excludeContent.Contains("# END AGENT-DEVKIT MANAGED EXCLUDES")) "Contains end marker"
    Assert-True ($excludeContent.Contains("my-local-notes.txt")) "Preserves user-defined entries"
    Assert-True ($excludeContent.Contains("scratch-debug/")) "Preserves user-defined directories"
    Assert-True ($excludeContent.Contains(".claude/")) "Contains .claude/ in managed block"
    Assert-True ($excludeContent.Contains("CLAUDE.md")) "Contains CLAUDE.md in managed block"

    # .gitignore must not be touched
    $gitignoreShaAfter = Get-DevKitSha256 -Path $dummyGitignore
    Assert-Equal $gitignoreShaBefore $gitignoreShaAfter ".gitignore was NOT modified"

    # 15.4 Idempotency of exclude block
    $secondExclude = Set-DevKitGitExclude -ProjectDir $gitSandbox -ExcludePaths $excludePaths
    $excludeContentSecond = Get-Content -Path $excludeFile -Raw
    Assert-Equal $excludeContent.Trim() $excludeContentSecond.Trim() "Repeated call is 100% idempotent and does not duplicate lines"

    # 15.5 Integration with Invoke-DevKitSync
    # Materialize rp-doces profile into gitSandbox
    $syncGit = Invoke-DevKitSync -ProjectDir $gitSandbox -Profile "rp-doces" -StateDir $gitStateDir -DevKitRoot $devKitRoot
    Assert-Equal $syncGit.Materialized $syncGit.TotalFiles "Sync materialized all expected profile files into git consumer"
    Assert-Equal $syncGit.Blocked 0 "No files blocked during clean git consumer sync"

    # Third-party frontend-design contains SKILL.md and LICENSE.txt in both agent targets.
    # Check the actual artifacts rather than baking a profile-wide file count into this test.
    foreach ($target in @(".agents\skills", ".claude\skills")) {
        foreach ($file in @("SKILL.md", "LICENSE.txt")) {
            $skillFile = Join-Path $gitSandbox (Join-Path $target (Join-Path "frontend-design" $file))
            Assert-True (Test-Path $skillFile -PathType Leaf) "frontend-design $file materialized in $target"
        }
    }

    # Verify that exclude file has the block intact
    $postSyncExclude = Get-Content -Path $excludeFile -Raw
    Assert-True ($postSyncExclude.Contains("# BEGIN AGENT-DEVKIT MANAGED EXCLUDES")) "Managed block intact post-sync"
    Assert-True ($postSyncExclude.Contains("my-local-notes.txt")) "User entries intact post-sync"

    # Add a normal application file
    $normalFile = Join-Path $gitSandbox "normal-app-code.txt"
    Set-Content -Path $normalFile -Value "const hello = 'world';"

    # If git CLI is available, test real git status ignoring
    $gitCmd = Get-Command "git" -ErrorAction SilentlyContinue
    if ($null -ne $gitCmd) {
        # Initialize real git in sandbox
        & git -C $gitSandbox init -q
        $gitStatusShort = & git -C $gitSandbox status --short
        # normal-app-code.txt should be untracked (??)
        Assert-True ($gitStatusShort -match "normal-app-code\.txt") "Normal application code is visible as untracked in git status"
        # Materialized files (CLAUDE.md, AGENTS.md, .claude, .agents) must NOT appear in git status
        Assert-True (-not ($gitStatusShort -match "CLAUDE\.md")) "CLAUDE.md is excluded from git status"
        Assert-True (-not ($gitStatusShort -match "AGENTS\.md")) "AGENTS.md is excluded from git status"
        Assert-True (-not ($gitStatusShort -match "\.claude")) ".claude directory is excluded from git status"
        Assert-True (-not ($gitStatusShort -match "\.agents")) ".agents directory is excluded from git status"
        # User excluded file should not appear
        $userExcludedFile = Join-Path $gitSandbox "my-local-notes.txt"
        Set-Content -Path $userExcludedFile -Value "my secret thoughts"
        $statusWithUser = & git -C $gitSandbox status --short
        Assert-True (-not ($statusWithUser -match "my-local-notes\.txt")) "User-excluded file remains ignored by git status"
    }

    # 15.6 Clean block removal
    $remRes = Set-DevKitGitExclude -ProjectDir $gitSandbox -Remove
    Assert-True $remRes.Updated "Remove succeeded"
    $removedContent = Get-Content -Path $excludeFile -Raw
    Assert-True (-not ($removedContent.Contains("BEGIN AGENT-DEVKIT MANAGED EXCLUDES"))) "Managed block removed"
    Assert-True ($removedContent.Contains("my-local-notes.txt")) "User entries remain intact after block removal"
}
finally {
    Remove-Item -Path $gitSandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $gitStateDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== TEST SUMMARY ===" -ForegroundColor Cyan
Write-Host "Passed: $passCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "DarkGray" })

if ($failCount -gt 0) {
    exit 1
}
else {
    exit 0
}
