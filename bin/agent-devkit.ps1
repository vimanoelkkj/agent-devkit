#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("sync", "verify", "list", "skill", "profile")]
    [string]$Command = "verify",

    [Parameter(Position = 1, Mandatory = $false)]
    [string]$Subcommand = $null,

    [Parameter(Position = 2, Mandatory = $false)]
    [string]$Target1 = $null,

    [Parameter(Position = 3, Mandatory = $false)]
    [string]$Target2 = $null,

    [Parameter(Mandatory = $false)]
    [string]$ProjectDir = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string]$ManifestFile = $null,

    [Parameter(Mandatory = $false)]
    [string]$Profile = $null,

    [Parameter(Mandatory = $false)]
    [string]$StateDir = $null,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoGitExclude
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$devKitRoot = Split-Path -Parent $scriptDir

$modulePath = Join-Path $devKitRoot "src\DevKit.Engine.psm1"
Import-Module $modulePath -Force -DisableNameChecking

$ProjectDir = (Resolve-Path $ProjectDir).Path

$explicitManifest = $null
if (-not [string]::IsNullOrWhiteSpace($ManifestFile)) {
    if (Test-Path $ManifestFile -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText((Resolve-Path $ManifestFile).Path, [System.Text.Encoding]::UTF8)
        $explicitManifest = $content | ConvertFrom-Json
    } else {
        throw "Specified manifest file not found: $ManifestFile"
    }
}

Write-Host "agent-devkit v1.0.0" -ForegroundColor Cyan
Write-Host "DevKit Root: $devKitRoot" -ForegroundColor DarkGray
if ($Command -in @("sync", "verify")) {
    Write-Host "Project Dir: $ProjectDir" -ForegroundColor DarkGray
    if ($Profile) {
        Write-Host "Profile:     $Profile" -ForegroundColor DarkGray
    }
    if ($StateDir) {
        Write-Host "State Dir:   $StateDir" -ForegroundColor DarkGray
    }
    if ($explicitManifest) {
        Write-Host "Manifest:    $ManifestFile" -ForegroundColor DarkGray
    }
}

$cmdDisplay = if ($Subcommand) { "$Command $Subcommand $(if ($Target1) { $Target1 }) $(if ($Target2) { $Target2 })".Trim() } else { $Command }
Write-Host "Command:     $cmdDisplay $(if ($DryRun) { '[DRY-RUN]' } else { '' })`n" -ForegroundColor DarkGray

switch ($Command) {
    "skill" {
        $sub = if ([string]::IsNullOrWhiteSpace($Subcommand)) { "list" } else { $Subcommand.ToLowerInvariant() }
        switch ($sub) {
            "list" {
                $catalog = Get-DevKitSkillCatalog -DevKitRoot $devKitRoot
                Write-Host "=== DEV-KIT SKILL CATALOG ===" -ForegroundColor Yellow
                $tableData = $catalog | ForEach-Object {
                    [PSCustomObject]@{
                        Name      = $_.Name
                        Category  = $_.Category
                        Ownership = $_.Ownership
                        State     = $_.State
                        Policy    = $_.Policy
                        Profiles  = ($_.Profiles -join ", ")
                        License   = $_.License
                    }
                }
                $tableData | Format-Table -AutoSize
            }
            "info" {
                if ([string]::IsNullOrWhiteSpace($Target1)) {
                    Write-Error "Usage: agent-devkit.ps1 skill info <skillName>"
                    exit 1
                }
                $info = Get-DevKitSkillInfo -SkillName $Target1 -DevKitRoot $devKitRoot
                if ($null -eq $info) {
                    Write-Error "Skill '$Target1' not found in DevKit catalog."
                    exit 1
                }
                Write-Host "Skill:        $($info.Name)" -ForegroundColor Cyan
                Write-Host "Category:     $($info.Category)"
                Write-Host "Ownership:    $($info.Ownership)"
                Write-Host "State:        $($info.State)"
                Write-Host "Source:       $($info.Source)"
                Write-Host "Policy:       $($info.Policy)"
                Write-Host "License:      $($info.License)"
                if ($info.Ref) {
                    Write-Host "Ref (Commit): $($info.Ref)"
                }
                if ($info.Subpath) {
                    Write-Host "Subpath:      $($info.Subpath)"
                }
                Write-Host "Path:         $($info.Path)"
                Write-Host "Profiles:     $($info.Profiles -join ', ')"
                if ($info.Description) {
                    Write-Host "`nDescription:`n  $($info.Description)" -ForegroundColor DarkGray
                }
            }
            default {
                Write-Error "Unknown skill subcommand '$Subcommand'. Available: list, info"
                exit 1
            }
        }
    }

    "profile" {
        $sub = if ([string]::IsNullOrWhiteSpace($Subcommand)) { "list" } else { $Subcommand.ToLowerInvariant() }
        switch ($sub) {
            "list" {
                $profiles = Get-DevKitProfileList -DevKitRoot $devKitRoot
                Write-Host "=== DEV-KIT PROFILES ===" -ForegroundColor Yellow
                $tableData = $profiles | ForEach-Object {
                    [PSCustomObject]@{
                        Profile      = $_.Name
                        Version      = $_.Version
                        Skills       = $_.SkillsCount
                        ThirdParty   = $_.ThirdPartyCount
                        Hooks        = $_.HooksCount
                        Instructions = $_.InstructionsCount
                        Rules        = $_.RulesCount
                        Agents       = $_.AgentsCount
                        Configs      = $_.ConfigsCount
                        Available    = $_.AvailableCount
                        Description  = $_.Description
                    }
                }
                $tableData | Format-Table -AutoSize
            }
            "show" {
                if ([string]::IsNullOrWhiteSpace($Target1)) {
                    Write-Error "Usage: agent-devkit.ps1 profile show <profileName>"
                    exit 1
                }
                $pObj = Get-DevKitProfile -ProfileName $Target1 -DevKitRoot $devKitRoot
                Write-Host "Profile:     $($pObj.name) (v$($pObj.version))" -ForegroundColor Green
                Write-Host "Description: $($pObj.description)" -ForegroundColor DarkGray

                Write-Host "`nDeclared Skills:" -ForegroundColor Cyan
                $catalog = Get-DevKitSkillCatalog -DevKitRoot $devKitRoot
                if ($pObj.skills) {
                    foreach ($s in $pObj.skills) {
                        $cEntry = $catalog | Where-Object { $_.Name -eq $s }
                        $cat = if ($cEntry) { $cEntry.Category } else { "unknown" }
                        Write-Host "  - $s ($cat)"
                    }
                }
                if ($pObj.thirdPartySkills) {
                    foreach ($t in $pObj.thirdPartySkills) {
                        Write-Host "  - $t (third-party)"
                    }
                }

                $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                if ($pObj.skills) { foreach ($s in $pObj.skills) { $declared.Add($s) | Out-Null } }
                $availableSkills = $catalog | Where-Object { $_.Category -eq "profile-specific" -and $_.Profile -eq $Target1 -and (-not $declared.Contains($_.Name)) }
                if ($availableSkills) {
                    Write-Host "`nAvailable Skills (undeclared in profile.json):" -ForegroundColor Yellow
                    foreach ($as in $availableSkills) {
                        Write-Host "  - $($as.Name) (profile-specific, available)"
                    }
                }

                Write-Host "`nDeclared Hooks:" -ForegroundColor Cyan
                if ($pObj.hooks) {
                    foreach ($h in $pObj.hooks) {
                        Write-Host "  - $h"
                    }
                }

                if ($pObj.instructions) {
                    Write-Host "`nDeclared Instructions:" -ForegroundColor Cyan
                    foreach ($i in $pObj.instructions) {
                        Write-Host "  - $i"
                    }
                }

                if ($pObj.rules) {
                    Write-Host "`nDeclared Rules:" -ForegroundColor Cyan
                    foreach ($r in $pObj.rules) {
                        Write-Host "  - $r"
                    }
                }

                if ($pObj.agents) {
                    Write-Host "`nDeclared Agents:" -ForegroundColor Cyan
                    foreach ($a in $pObj.agents) {
                        Write-Host "  - $a"
                    }
                }

                if ($pObj.configs) {
                    Write-Host "`nDeclared Configs:" -ForegroundColor Cyan
                    foreach ($c in $pObj.configs) {
                        $display = if ($c -is [string]) { $c } else { "$($c.source) -> $($c.target)" }
                        Write-Host "  - $display"
                    }
                }

                if ($pObj.overlays) {
                    Write-Host "`nDeclared Overlays:" -ForegroundColor Cyan
                    foreach ($o in $pObj.overlays) {
                        $display = if ($o -is [string]) { $o } else { "$($o.source) -> $($o.target)" }
                        Write-Host "  - $display"
                    }
                }
            }
            "add" {
                if ([string]::IsNullOrWhiteSpace($Target1) -or [string]::IsNullOrWhiteSpace($Target2)) {
                    Write-Error "Usage: agent-devkit.ps1 profile add <profileName> <skillName>"
                    exit 1
                }
                $res = Add-DevKitProfileSkill -ProfileName $Target1 -SkillName $Target2 -DevKitRoot $devKitRoot
                Write-Host "SUCCESS: $($res.Message)" -ForegroundColor Green
            }
            "remove" {
                if ([string]::IsNullOrWhiteSpace($Target1) -or [string]::IsNullOrWhiteSpace($Target2)) {
                    Write-Error "Usage: agent-devkit.ps1 profile remove <profileName> <skillName>"
                    exit 1
                }
                $res = Remove-DevKitProfileSkill -ProfileName $Target1 -SkillName $Target2 -DevKitRoot $devKitRoot
                Write-Host "SUCCESS: $($res.Message)" -ForegroundColor Yellow
            }
            default {
                Write-Error "Unknown profile subcommand '$Subcommand'. Available: list, show, add, remove"
                exit 1
            }
        }
    }

    "list" {
        Write-Host "=== CORE SKILLS ===" -ForegroundColor Yellow
        $coreSkills = Get-ChildItem -Path (Join-Path $devKitRoot "core\skills") -Directory -ErrorAction SilentlyContinue
        foreach ($s in $coreSkills) {
            Write-Host "  - $($s.Name)"
        }

        Write-Host "`n=== CORE HOOKS ===" -ForegroundColor Yellow
        $coreHooks = Get-ChildItem -Path (Join-Path $devKitRoot "core\hooks") -File -ErrorAction SilentlyContinue
        foreach ($h in $coreHooks) {
            Write-Host "  - $($h.Name)"
        }

        Write-Host "`n=== PROFILES ===" -ForegroundColor Yellow
        $profiles = Get-ChildItem -Path (Join-Path $devKitRoot "profiles") -Directory -ErrorAction SilentlyContinue
        foreach ($p in $profiles) {
            Write-Host "  Profile: $($p.Name)" -ForegroundColor Green
            $pSkills = Get-ChildItem -Path (Join-Path $p.FullName "skills") -Directory -ErrorAction SilentlyContinue
            if ($pSkills) {
                Write-Host "    Skills:" -ForegroundColor DarkCyan
                foreach ($ps in $pSkills) {
                    Write-Host "      - $($ps.Name)"
                }
            }
            $pHooks = Get-ChildItem -Path (Join-Path $p.FullName "hooks") -File -ErrorAction SilentlyContinue
            if ($pHooks) {
                Write-Host "    Hooks:" -ForegroundColor DarkCyan
                foreach ($ph in $pHooks) {
                    Write-Host "      - $($ph.Name)"
                }
            }
        }

        Write-Host "`n=== THIRD-PARTY REGISTRY ===" -ForegroundColor Yellow
        $tpReg = Get-DevKitThirdPartyRegistry -DevKitRoot $devKitRoot
        if ($tpReg -and $tpReg.registry) {
            foreach ($prop in $tpReg.registry.PSObject.Properties) {
                $item = $prop.Value
                Write-Host "  $($prop.Name)" -ForegroundColor Cyan
                Write-Host "    Source:  $($item.type):$($item.repo)@$($item.ref)" -ForegroundColor DarkGray
                Write-Host "    Subpath: $($item.subpath)" -ForegroundColor DarkGray
                Write-Host "    Policy:  $($item.policy)" -ForegroundColor DarkGray
                Write-Host "    License: $($item.license)" -ForegroundColor DarkGray
            }
        }
    }

    "verify" {
        $result = Invoke-DevKitVerify -ProjectDir $ProjectDir -Profile $Profile -StateDir $StateDir -Manifest $explicitManifest -DevKitRoot $devKitRoot
        Write-Host "Total Managed Targets: $($result.TotalFiles)"

        if ($result.Verified) {
            Write-Host "`nSUCCESS: All managed components are strictly synchronized." -ForegroundColor Green
            exit 0
        }
        else {
            Write-Host "`nDISCREPANCIES FOUND ($($result.Discrepancies.Count)):" -ForegroundColor Yellow
            $result.Discrepancies | Format-Table Type, Component, Status, Target, Description -AutoSize
            exit 1
        }
    }

    "sync" {
        $result = Invoke-DevKitSync -ProjectDir $ProjectDir -Profile $Profile -StateDir $StateDir -Manifest $explicitManifest -DryRun:$DryRun -NoGitExclude:$NoGitExclude -DevKitRoot $devKitRoot

        Write-Host "Execution Summary:"
        Write-Host "  Total Files Evaluated: $($result.TotalFiles)"
        Write-Host "  Already Synced:        $($result.Synced)" -ForegroundColor Green
        Write-Host "  Materialized / Copied: $($result.Materialized)" -ForegroundColor Cyan
        Write-Host "  Missing Detected:      $($result.Missing)" -ForegroundColor $(if ($result.Missing -gt 0) { 'Yellow' } else { 'DarkGray' })
        Write-Host "  Blocked / Warnings:    $($result.Blocked)" -ForegroundColor $(if ($result.Blocked -gt 0) { 'Red' } else { 'DarkGray' })

        if ($result.State.Count -gt 0) {
            Write-Host "`nDetailed Status:"
            $result.State | Format-Table Type, Component, Status, Target -AutoSize
        }

        if ($DryRun) {
            Write-Host "`n[DRY-RUN] No files were modified in the target project." -ForegroundColor Magenta
        }
        elseif ($result.Blocked -gt 0) {
            Write-Host "`nWARNING: Some files were blocked to protect local modifications." -ForegroundColor Yellow
            exit 2
        }
        else {
            Write-Host "`nSync completed successfully." -ForegroundColor Green
        }
    }
}
