#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("sync", "verify", "list")]
    [string]$Command = "verify",

    [Parameter(Mandatory = $false)]
    [string]$ProjectDir = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string]$ManifestFile = $null,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
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
Write-Host "Project Dir: $ProjectDir" -ForegroundColor DarkGray
if ($explicitManifest) {
    Write-Host "Manifest:    $ManifestFile" -ForegroundColor DarkGray
}
Write-Host "Command:     $Command $(if ($DryRun) { '[DRY-RUN]' } else { '' })`n" -ForegroundColor DarkGray

switch ($Command) {
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
        $result = Invoke-DevKitVerify -ProjectDir $ProjectDir -Manifest $explicitManifest -DevKitRoot $devKitRoot
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
        $result = Invoke-DevKitSync -ProjectDir $ProjectDir -Manifest $explicitManifest -DryRun:$DryRun -DevKitRoot $devKitRoot

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
