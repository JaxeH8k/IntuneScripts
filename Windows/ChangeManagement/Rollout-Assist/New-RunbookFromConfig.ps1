<#
.SYNOPSIS
    Generates a fully populated Intune rollout runbook from Rollout-Config.psd1.

.DESCRIPTION
    Reads all values from Rollout-Config.psd1 and produces a completed Markdown
    runbook with no [CUSTOMIZE] placeholders remaining for fields that are defined
    in the config.

    The output file is named:
        Runbook-[ChangeId]-[YYYY-MM-DD].md

    and is written to the same directory as the config file (or to -OutputPath if specified).

.PARAMETER ConfigFile
    Path to Rollout-Config.psd1. Defaults to .\Rollout-Config.psd1.

.PARAMETER OutputPath
    Directory to write the generated runbook into.
    Defaults to the directory containing ConfigFile.

.EXAMPLE
    # Generate runbook from config in the current directory
    .\New-RunbookFromConfig.ps1

.EXAMPLE
    # Specify paths explicitly
    .\New-RunbookFromConfig.ps1 -ConfigFile "C:\Rollouts\Rollout-Config.psd1" -OutputPath "C:\Rollouts\Runbooks"

.NOTES
    Version : 1.0
    No Graph connection required — this script only reads the local config file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile = '.\Rollout-Config.psd1',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load config ───────────────────────────────────────────────────────────────
Write-Host "`n==> Loading config from '$ConfigFile'..." -ForegroundColor Cyan
$cfg = Import-PowerShellDataFile -Path (Resolve-Path $ConfigFile)

# Resolve output directory
if (-not $OutputPath) {
    $OutputPath = Split-Path (Resolve-Path $ConfigFile) -Parent
}
if (-not (Test-Path $OutputPath)) { New-Item $OutputPath -ItemType Directory | Out-Null }

$today      = Get-Date -Format 'yyyy-MM-dd'
$outFile    = Join-Path $OutputPath "Runbook-$($cfg.ChangeId)-$today.md"

# ── Helper: format ring table row ─────────────────────────────────────────────
function Get-RingSizeLabel {
    param([int]$RingNumber, [int]$FleetSize)
    switch ($RingNumber) {
        0 { return "~50–100 devices" }
        1 { $n = [math]::Round($FleetSize * 0.01); return "~1% (~$n devices)" }
        2 { $n = [math]::Round($FleetSize * 0.10); return "~10% (~$n devices)" }
        3 { $n = [math]::Round($FleetSize * 0.89); return "~89% (~$n devices)" }
    }
}

function Get-SoakLabel { param([int]$Days); if ($Days -eq 1) { return "1 day" } else { return "$Days days" } }

# ── Helper: per-ring script block ─────────────────────────────────────────────
function Get-RingScriptBlock {
    param($ring, $cfg)
    $oldPolicyParam = if ($cfg.OldPolicyId) { "`n       -OldPolicyId `"$($cfg.OldPolicyId)`"" } else { '' }
    return @"
``````powershell
# Dry run
.\Invoke-IntuneRingAssignment.ps1 ``
    -ConfigFile .\Rollout-Config.psd1 ``
    -RingNumber $($ring.Number) ``
    -WhatIf

# Live
.\Invoke-IntuneRingAssignment.ps1 ``
    -ConfigFile .\Rollout-Config.psd1 ``
    -RingNumber $($ring.Number)
``````

> **Policy:** ``$($cfg.PolicyId)``
> **Group:**  ``$($ring.GroupId)`` ($($ring.GroupName))$(if ($cfg.OldPolicyId) { "`n> **Old policy excluded:** ``$($cfg.OldPolicyId)``" })
"@
}

# ── Build ring table ──────────────────────────────────────────────────────────
$ringTableRows = foreach ($r in ($cfg.Rings | Sort-Object Number)) {
    $size  = Get-RingSizeLabel -RingNumber $r.Number -FleetSize $cfg.FleetSize
    $soak  = Get-SoakLabel -Days $r.SoakDays
    $notes = switch ($r.Number) {
        0 { "Admin-owned devices only; first full validation" }
        1 { "Cover multiple platforms, BUs, geographies" }
        2 { "Catches scale-related issues before full rollout" }
        3 { "Monitor for long-tail failures; consider 2-tranche split if user-visible" }
    }
    "| **Ring $($r.Number) — $($r.Description)** | $($r.GroupName) | $size | $soak | $notes |"
}
$ringTable = $ringTableRows -join "`n"

# ── Build deployment steps ────────────────────────────────────────────────────
$deploymentSteps = foreach ($r in ($cfg.Rings | Sort-Object Number)) {
    $soakLabel = Get-SoakLabel -Days $r.SoakDays
    $scriptBlock = Get-RingScriptBlock -ring $r -cfg $cfg

    switch ($r.Number) {
        0 {
@"

### Ring 0 — IT / Pilot ($($r.Description))

**Soak period:** $soakLabel | **Group:** $($r.GroupName)

1. **Dry run first** — confirm the assignment looks correct without making changes:

$scriptBlock

2. Confirm the assignment appears under the profile's **Device status** tab in Intune within 15 minutes.
3. On 2–3 Ring 0 devices, trigger an immediate sync:
   Settings > Accounts > Access work or school > [account] > Info > Sync, or Company Portal > Devices > [device] > Check status
4. Validate the profile applied (see §6 Validation).
5. Monitor **Device configuration – Monitor** for $soakLabel.
6. Evaluate go/no-go criteria (§7) before proceeding to Ring 1.
"@
        }
        1 {
@"

### Ring 1 — Early Adopters ($($r.Description))

**Soak period:** $soakLabel | **Group:** $($r.GroupName)

1. Send pre-deployment communication to Ring 1 participants (see §9 template).

$scriptBlock

2. Monitor Intune **Device status** for Ring 1 group daily.
3. Track helpdesk tickets tagged ``$($cfg.ChangeId)`` daily.
4. Evaluate go/no-go before Ring 2.
"@
        }
        2 {
@"

### Ring 2 — Limited Broad ($($r.Description))

**Soak period:** $soakLabel | **Group:** $($r.GroupName)

1. Verify Ring 2 group membership spans multiple business units, geographies, and device models.

$scriptBlock

2. Monitor Intune **Device status** daily.
3. Evaluate go/no-go before Ring 3.
"@
        }
        3 {
@"

### Ring 3 — Broad Deployment ($($r.Description))

**Soak period:** $soakLabel | **Group:** $($r.GroupName)

1. Notify helpdesk and stakeholders that broad rollout is beginning.

$scriptBlock

2. At ~$([math]::Round($cfg.FleetSize * 0.89).ToString('N0')) devices, expect check-in completion to take 24–48 hours. Use **Bulk Device Actions > Sync** on the Ring 3 group to accelerate if needed.
3. After $soakLabel with no Stop conditions, proceed to §10 post-deployment tasks.
"@
        }
    }
}
$deploymentStepsText = $deploymentSteps -join "`n"

# ── Pre-deployment checklist: per-ring group lines ────────────────────────────
$groupChecklist = ($cfg.Rings | Sort-Object Number | ForEach-Object {
    "- [ ] **Ring $($_.Number) ($($_.Description))** Group ID recorded: ``$($_.GroupId)``  | Group name: $($_.GroupName)"
}) -join "`n"

# ── Summary block ─────────────────────────────────────────────────────────────
$summaryText = if ($cfg.ChangeSummary) { $cfg.ChangeSummary } else {
    "Deploying configuration profile **$($cfg.PolicyName)** to all managed $($cfg.Platform) devices (~$($cfg.FleetSize.ToString('N0')) total). [CUSTOMIZE: Add 2–4 sentences describing what this profile does and why it is being deployed.]"
}

$oldPolicySentence = if ($cfg.OldPolicyId) {
    "This deployment **replaces** an existing policy (``$($cfg.OldPolicyId)``). Ring groups will be excluded from the old policy as they receive the new one to prevent overlap."
} else {
    "This is a **brand-new profile** — no predecessor policy is currently targeting these devices, so there is no overlap risk."
}

# ── Assemble the runbook ──────────────────────────────────────────────────────
$runbook = @"
# Intune Staged Rollout Runbook: $($cfg.ChangeTitle)

**Change ID:** $($cfg.ChangeId)
**Owner:** $($cfg.Owner)
**Prepared:** $today
**Target fleet:** ~$($cfg.FleetSize.ToString('N0')) devices
**Change type:** Device Configuration Profile
**Urgency:** Standard

---

## 1. Change Summary

$summaryText

$oldPolicySentence

**Affected platforms:** $($cfg.Platform)
**Intune object name:** $($cfg.PolicyName)
**Policy ID:** ``$($cfg.PolicyId)``
**Assigned via:** $($cfg.AssignedVia)

---

## 2. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Profile conflicts with an existing CSP or overlapping policy | Medium | High | Run a settings conflict check in Intune before Ring 0 |
| Devices in a poor network state fail to sync | Low | Medium | Monitor check-in rate in Ring 0 for $((($cfg.Rings | Where-Object Number -eq 0).SoakDays)) days |
| Profile causes unexpected behavior on certain device models | Low | Medium | Ensure Ring 0 and Ring 1 include a representative hardware sample |
| AAD dynamic group replication lag delays scope | Medium | Low | Allow 30 min after group save before expecting devices in scope |
| Large Ring 3 rollout generates helpdesk volume | Low | Medium | Pre-brief helpdesk with change ID $($cfg.ChangeId) and expected symptom set |

**Overall risk rating:** Low–Medium

> **100k+ fleet note:** Intune reporting slows significantly at this scale. Use Log Analytics / Azure Monitor Workbooks or Graph API exports for near-real-time visibility during Ring 3.

---

## 3. Deployment Rings

| Ring | Group | Size | Soak period | Notes |
|---|---|---|---|---|
$ringTable

**AAD group naming convention:** $((($cfg.Rings | Sort-Object Number | ForEach-Object { $_.GroupName }) -join ', '))

---

## 4. Pre-Deployment Checklist

- [ ] Change approved in ITSM (Change ID: **$($cfg.ChangeId)**)
- [ ] Config profile created and reviewed: **$($cfg.PolicyName)** (``$($cfg.PolicyId)``)
- [ ] Profile settings validated in a lab / non-production tenant
- [ ] No conflicting profiles — checked Devices > Configuration profiles for overlapping OMA-URI / Settings Catalog entries
$groupChecklist
- [ ] ``Microsoft.Graph.Authentication`` module installed and ``Connect-MgGraph`` tested successfully
- [ ] ``Rollout-Config.psd1`` reviewed — all GUIDs confirmed correct
- [ ] Rollback procedure reviewed and approved by **$($cfg.RollbackOwner)**
- [ ] Intune **Device status** monitor saved for this profile
- [ ] Communication sent to Ring 0 participants
- [ ] Helpdesk briefed: contact $($cfg.HelpdeskContact) | reference change ID **$($cfg.ChangeId)**

---

## 5. Deployment Steps

> **Before any ring:** Authenticate to Microsoft Graph:
> ``````powershell
> Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # first time only
> Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
> ``````
>
> All ring steps use ``Invoke-IntuneRingAssignment.ps1`` with ``-ConfigFile .\Rollout-Config.psd1``.
> **Always run with ``-WhatIf`` first, then live.**
$deploymentStepsText

---

## 6. Validation Steps

After each ring's soak period, confirm the profile applied correctly.

**In Intune portal:**
- Navigate to **Devices > Configuration profiles > $($cfg.PolicyName) > Device status**
- Confirm **Succeeded** count is growing and **Error / Conflict** is < 1% of assigned devices
- Filter by ring group to isolate per-ring status

**On a sample endpoint (per ring):**
- [CUSTOMIZE: Add the specific check for your profile type — e.g., registry key, Settings app value, Event Viewer entry]
- Event Viewer: ``Applications and Services Logs > Microsoft > Windows > DeviceManagement-Enterprise-Diagnostics-Provider > Admin``

**For Ring 2 / Ring 3 at scale:**
- Export device status via Graph for bulk analysis if the portal is slow:
  ``GET https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($cfg.PolicyId)/deviceStatuses``
- Consider an **Azure Monitor Workbook** or **Log Analytics** query against ``IntuneDeviceComplianceOrg``

---

## 7. Go / No-Go Criteria

Evaluate after each ring's soak period. **Do not advance** to the next ring if any Stop condition is met.

| Metric | ✅ Go | ⚠️ Caution | 🛑 Stop |
|---|---|---|---|
| Policy apply success rate | ≥ 98% | 95–97% | < 95% |
| Sync errors related to this policy | 0 | 1–3 isolated | > 3 or systemic |
| Helpdesk tickets tagged $($cfg.ChangeId) | 0–2 | 3–5 | > 5 or any P1/P2 |
| User-reported productivity impact | None | Minor, isolated | Widespread |
| Endpoint Analytics score delta | Neutral / improved | < 2 pt drop | > 2 pt drop |
| Profile conflict warnings | 0 | 1–2 isolated | Any pattern |

**Decision owner:** $($cfg.DecisionOwner)
**Escalation contact:** $($cfg.EscalationContact)

---

## 8. Rollback Procedure

**Rollback trigger:** Any Stop condition in §7, or explicit instruction from the Change Owner.

### Rollback steps

1. **In Intune portal:** Navigate to **Devices > Configuration profiles > $($cfg.PolicyName) > Assignments** — remove the affected ring group from the Include assignment and save.
2. To accelerate revert, trigger a bulk sync: **Devices > All devices** > filter by ring group > select all > **Sync**.
3. Devices revert on next check-in — typically within 8 hours organically, ~1–2 hours if force-synced.
4. Verify in **Device status** tab — affected devices should show **Not applicable** after re-check-in.
5. [CUSTOMIZE: Add any manual remediation steps if the profile is not fully self-reverting.]
6. Open a change failure record in ITSM under **$($cfg.ChangeId)**.
7. Root cause analysis required before re-attempting deployment.

**Rollback owner:** $($cfg.RollbackOwner)
**Estimated rollback time:** ~8 hours via natural check-in; ~1–2 hours if force-synced via bulk action

---

## 9. Communication Plan

### Pre-deployment (send 24h before Ring 1 and Ring 2)

> **Subject:** Upcoming configuration update to your device – $($cfg.ChangeId)
>
> Hi [Ring audience],
>
> As part of [project/initiative], IT will be deploying a new configuration setting to your managed device starting [date]. This change [will / will not] require a restart and should happen automatically in the background.
>
> If you experience any unexpected behavior, please contact $($cfg.HelpdeskContact) and reference change ID **$($cfg.ChangeId)**.
>
> Thank you,
> $($cfg.ITTeamName)

### Broad deployment notice (Ring 3 start)
Notify all-staff / IT stakeholders that the broad rollout has begun. Include change ID, expected completion date, and helpdesk contact.

### Post-deployment (after Ring 3 soak complete)
Send a completion notice to stakeholders with final success metrics and any issues resolved.

---

## 10. Post-Deployment Tasks

- [ ] Mark change as **Complete** in ITSM (Change ID: **$($cfg.ChangeId)**)
- [ ] Confirm final success rate ≥ 98% across all rings in Intune **Device status**
- [ ] Update device configuration documentation with profile details
- [ ] Archive Ring AAD groups — rename to ``ARCHIVE-$($cfg.ChangeId)-RingN`` (do **not** delete)
- [ ] Schedule a **30-day health check** in Endpoint Analytics
- [ ] Share lessons learned with $($cfg.ITTeamName)

---

## Appendix: Quick Reference

| Item | Value |
|---|---|
| Policy name | $($cfg.PolicyName) |
| Policy ID | ``$($cfg.PolicyId)`` |
| Old policy ID | $(if ($cfg.OldPolicyId) { "``$($cfg.OldPolicyId)``" } else { "N/A (new deployment)" }) |
$(($cfg.Rings | Sort-Object Number | ForEach-Object { "| Ring $($_.Number) group ($($_.Description)) | ``$($_.GroupId)`` |" }) -join "`n")
| Decision owner | $($cfg.DecisionOwner) |
| Escalation | $($cfg.EscalationContact) |
| Rollback owner | $($cfg.RollbackOwner) |
| Helpdesk | $($cfg.HelpdeskContact) |

### Ring command reference

``````powershell
# Connect first (once per session)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"

# Ring 0 — dry run then live
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 0 -WhatIf
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 0

# Ring 1
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 1 -WhatIf
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 1

# Ring 2
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 2 -WhatIf
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 2

# Ring 3
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 3 -WhatIf
.\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 3
``````
"@

# ── Write output ──────────────────────────────────────────────────────────────
$runbook | Set-Content -Path $outFile -Encoding UTF8
Write-Host "`n==> Runbook written to:" -ForegroundColor Green
Write-Host "    $outFile" -ForegroundColor White
Write-Host ""
Write-Host "    Next: open Rollout-Config.psd1, fill in any remaining GUIDs," -ForegroundColor Gray
Write-Host "    then re-run this script to regenerate the runbook." -ForegroundColor Gray
Write-Host ""
