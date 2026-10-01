# tests/devkit-engine.test.ps1
# Automated unit & integration tests for agent-devkit engine

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$devKitRoot = Split-Path -Parent $scriptDir

$modulePath = Join-Path $devKitRoot "src\DevKit.Engine.psm1"
Import-Module $modulePath -Force

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

# Test 3: Component Resolution for Hooks (Core vs Profile)
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
    # 3 skills x 2 targets = 6 + 2 hooks x 1 target = 2 -> total 8
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

Write-Host "`n=== TEST SUMMARY ===" -ForegroundColor Cyan
Write-Host "Passed: $passCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "DarkGray" })

if ($failCount -gt 0) {
    exit 1
}
else {
    exit 0
}
