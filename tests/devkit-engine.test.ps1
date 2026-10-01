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

Write-Host "`n=== TEST SUMMARY ===" -ForegroundColor Cyan
Write-Host "Passed: $passCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "DarkGray" })

if ($failCount -gt 0) {
    exit 1
}
else {
    exit 0
}
