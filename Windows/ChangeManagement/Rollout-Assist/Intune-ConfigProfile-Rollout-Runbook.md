# Intune Staged Rollout Runbook: Device Configuration Profile Deployment

**Change ID:** [e.g., CHG-2026-NNNN]
**Owner:** [Name / Team]
**Prepared:** 2026-02-24
**Target fleet:** ~100,000+ devices
**Change type:** Device Configuration Profile
**Urgency:** Standard

---

## 1. Change Summary

This runbook covers the staged rollout of a new device configuration profile to the full managed
fleet (~100,000 devices). The profile is a **brand-new assignment** — no predecessor policy is
currently targeting these devices for this setting, so there is no overlap risk.

The deployment follows a four-ring model to detect issues early and limit blast radius. Each ring
has a defined soak period and go/no-go criteria that must be satisfied before advancing.

**Affected platforms:** [Windows 10/11 / macOS / iOS / Android — CUSTOMIZE]
**Intune object name:** [Exact profile name as it appears in Intune — CUSTOMIZE]
**Assigned via:** [Dynamic AAD group / Static group / Enrollment filter — CUSTOMIZE]

---

## 2. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Profile conflicts with an existing CSP or policy | Medium | High | Run a settings conflict check in Intune before Ring 0 |
| Devices in a poor network state fail to sync | Low | Medium | Monitor check-in rate in Ring 0 for 48–72 h |
| Profile causes unexpected behavior on certain device models | Low | Medium | Ensure Ring 0 and Ring 1 include a representative hardware sample |
| AAD dynamic group replication lag delays scope | Medium | Low | Allow 30 min after group save before expecting devices in scope |
| Large Ring 3 rollout overwhelms helpdesk | Low | Medium | Pre-brief helpdesk; stagger Ring 3 if user-visible impact is likely |

**Overall risk rating:** Low–Medium

> **100k+ fleet note:** Intune reporting can be slow with large result sets at this scale.
> Use Log Analytics / Azure Monitor Workbooks or Graph API exports for near-real-time visibility
> during Ring 3.

---

## 3. Deployment Rings

> Ring sizes shown as % of total fleet and approximate device count based on ~100,000 devices.
> Adjust to match your org's existing AAD group structure.

| Ring | Target | Size | Soak period | Notes |
|---|---|---|---|---|
| **Ring 0 — IT / Pilot** | IT team + test devices | ~50–100 devices | 48–72 hours | Admin-owned devices only; first full validation |
| **Ring 1 — Early Adopters** | Volunteers / power users | ~1% (~1,000 devices) | 5–7 days | Cover multiple platforms, business units, geographies |
| **Ring 2 — Limited Broad** | Business unit sample | ~10% (~10,000 devices) | 5–7 days | Catches scale-related issues before full rollout |
| **Ring 3 — Broad** | All remaining managed devices | ~89% (~89,000 devices) | 7 days | Monitor for long-tail failures; consider a 2-tranche split (see note below) |

**AAD group naming convention (suggested):**
`Intune-[ChangeID]-Ring0`, `Intune-[ChangeID]-Ring1`, `Intune-[ChangeID]-Ring2`, `Intune-[ChangeID]-Ring3`

> **Ring 3 stagger option:** For changes with any user-visible impact, consider splitting Ring 3
> into two tranches (e.g., 30% → 48h gap → remaining 59%) to give the helpdesk time to absorb
> tickets before the final push.

---

## 4. Pre-Deployment Checklist

Complete **all** items before starting Ring 0.

- [ ] Change approved in ITSM (Change ID: ___________________)
- [ ] Configuration profile created and reviewed in Intune tenant: [portal link or profile name]
- [ ] Profile settings validated in a lab / non-production tenant (if available)
- [ ] No conflicting profiles identified — run **Devices > Configuration profiles** and filter for the same OMA-URI / settings catalog entries
- [ ] AAD groups created and membership verified for Ring 0
- [ ] Ring 1, 2, 3 groups created (can pre-stage membership; assignment added per ring)
- [ ] **PolicyId** (GUID) recorded: `_________________________________________`
- [ ] **Ring 0 Group Object ID** recorded: `_____________________________________`
- [ ] **Ring 1 Group Object ID** recorded: `_____________________________________`
- [ ] **Ring 2 Group Object ID** recorded: `_____________________________________`
- [ ] **Ring 3 Group Object ID** recorded: `_____________________________________`
- [ ] `Microsoft.Graph.Authentication` module installed and `Connect-MgGraph` tested
- [ ] Rollback procedure reviewed and approved by team lead
- [ ] Intune **Device status** monitor saved / bookmarked for this profile
- [ ] Communication sent to Ring 0 participants
- [ ] Helpdesk briefed with change ID and expected symptom set

---

## 5. Deployment Steps

> **Before any ring:** Authenticate to Microsoft Graph:
> ```powershell
> Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # first time only
> Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
> ```
>
> The script `scripts/Invoke-IntuneRingAssignment.ps1` is included alongside this runbook.
> Always run with `-WhatIf` first, then live.

---

### Ring 0 — IT / Pilot

**Start date:** [Date]
**End / go-no-go date:** [Start + 3 days]

1. **Dry run** — verify the assignment looks correct without making changes:
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring0-GroupId]" `
       -WhatIf
   ```

2. **Live run** — assign Ring 0 group to the profile:
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring0-GroupId]"
   ```

3. Confirm the assignment appears under the profile's **Device status** tab in Intune within 15 minutes.

4. On 2–3 Ring 0 devices, trigger an immediate sync:
   - **Settings > Accounts > Access work or school > [account] > Info > Sync**, or
   - Company Portal > Devices > [device] > Check status

5. After sync, validate the profile applied (see §6).

6. Monitor **Device configuration – Monitor** error rates for 48–72 hours.

7. Evaluate go/no-go criteria (§7) before proceeding to Ring 1.

---

### Ring 1 — Early Adopters

**Start date:** [Ring 0 start + 3 days, if go]
**End / go-no-go date:** [Start + 7 days]

1. Send pre-deployment communication to Ring 1 participants (see §9 template).

2. **Dry run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring1-GroupId]" `
       -WhatIf
   ```

3. **Live run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring1-GroupId]"
   ```

4. Monitor Intune **Device status** for Ring 1 group — check daily.

5. Track helpdesk tickets tagged `[ChangeID]` daily.

6. Evaluate go/no-go before Ring 2.

---

### Ring 2 — Limited Broad

**Start date:** [Ring 1 complete + 2 days, if go]
**End / go-no-go date:** [Start + 7 days]

1. Verify Ring 2 group membership has good cross-section of business units, geographies, and device models.

2. **Dry run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring2-GroupId]" `
       -WhatIf
   ```

3. **Live run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring2-GroupId]"
   ```

4. Monitor at increased frequency — check Intune **Device status** daily.

5. Evaluate go/no-go before Ring 3.

---

### Ring 3 — Broad Deployment

**Start date:** [Ring 2 complete + 2 days, if go]
**Soak period:** 7 days minimum before declaring complete

1. Notify stakeholders and helpdesk that broad rollout is beginning.

2. **Dry run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring3-GroupId]" `
       -WhatIf
   ```

3. **Live run:**
   ```powershell
   .\scripts\Invoke-IntuneRingAssignment.ps1 `
       -PolicyId "[PolicyId]" `
       -GroupId  "[Ring3-GroupId]"
   ```

4. Monitor for 7 days. At this scale (~89,000 devices), expect check-in completion to take
   24–48 hours naturally — use **Bulk Device Actions > Sync** on the Ring 3 group to accelerate
   if needed.

5. After 7 days with no Stop conditions, proceed to §10 post-deployment tasks.

---

## 6. Validation Steps

Perform after each ring's soak period on a sample of devices.

### Intune portal checks
- Navigate to **Devices > Configuration profiles > [Profile name] > Device status**
- Confirm **Succeeded** count is growing and **Error / Conflict** count is < 1% of assigned devices
- Filter by ring group to isolate per-ring status

### On a sample endpoint (per ring)
- [CUSTOMIZE: Add the specific validation check for your profile type, e.g.:]
  - **Registry key:** `reg query HKLM\...\[setting path]` and confirm expected value
  - **Settings app:** Navigate to the relevant settings page and confirm the value is applied and greyed out (managed)
  - **Event Viewer:** `Applications and Services Logs > Microsoft > Windows > DeviceManagement-Enterprise-Diagnostics-Provider > Admin` — look for successful policy application events

### For large rings (Ring 2 / Ring 3)
- Export device status via **Microsoft Graph** for bulk analysis if Intune portal is slow:
  ```
  GET https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/{id}/deviceStatuses
  ```
- Consider an **Azure Monitor Workbook** or **Log Analytics** query against the `IntuneDeviceComplianceOrg` table for real-time visibility

---

## 7. Go / No-Go Criteria

Evaluate after each ring's soak period. **Do not proceed** to the next ring if any Stop condition is met.

| Metric | ✅ Go (Proceed) | ⚠️ Caution (Investigate) | 🛑 Stop (Halt + Escalate) |
|---|---|---|---|
| Policy apply success rate | ≥ 98% | 95–97% | < 95% |
| Device sync errors related to this policy | 0 | 1–3 isolated | > 3 or systemic pattern |
| Helpdesk tickets tagged to change | 0–2 (noise) | 3–5 | > 5, or any P1/P2 raised |
| User-reported productivity impact | None | Minor, isolated reports | Widespread or business-critical |
| Endpoint Analytics score delta | Neutral / improved | < 2 pt drop | > 2 pt drop |
| Profile conflict warnings in Intune | 0 | 1–2 isolated | Any pattern across devices |

**Decision owner:** [Name / Role]
**Escalation contact:** [Name / Role]

---

## 8. Rollback Procedure

> Test rollback steps before Ring 0 if possible. Config profiles are reversible — removing the
> assignment causes Intune to unenroll the policy on next check-in.

**Rollback trigger:** Any "Stop" condition in §7, or explicit instruction from the Change Owner.

### Rollback steps

1. **In Intune portal:** Navigate to **Devices > Configuration profiles > [Profile name] > Assignments**
   — remove the affected ring group from the Include assignment and save.

2. Alternatively, target a bulk sync to accelerate revert:
   - **Devices > All devices** > filter by ring group > select all > **Sync**

3. Devices will receive the updated (empty) assignment on next check-in — typically within 8 hours
   organically, or ~1–2 hours if force-synced.

4. Verify rollback in **Device status** tab — affected devices should show **"Not applicable"**
   once they have re-checked in.

5. [CUSTOMIZE: Add any manual remediation steps if the profile is not fully self-reverting,
   e.g., a registry key that was set and won't auto-clear on profile removal]

6. Open a change failure record in ITSM and tag it to `[ChangeID]`.

7. Root cause analysis required before re-attempting deployment.

**Rollback owner:** [Name]
**Estimated rollback time:** ~8 hours via natural check-in; ~1–2 hours if force-synced via bulk action

---

## 9. Communication Plan

### Pre-deployment (send 24h before Ring 1 and Ring 2)

> **Subject:** Upcoming configuration update to your device – [ChangeID]
>
> Hi [Ring audience name],
>
> As part of [project/initiative], IT will be deploying a new configuration setting to your
> managed device starting [date]. This change [will / will not] require a restart and should
> happen automatically in the background.
>
> You may see a brief sync notification from Company Portal. If you experience any unexpected
> behavior after [date], please contact the helpdesk at [link/phone/Teams channel] and
> reference **change ID [ChangeID]**.
>
> Thank you,
> [IT Team Name]

### Broad deployment notice (Ring 3 start)

Notify all-staff / IT stakeholders that the broad rollout has begun. Include the change ID,
expected completion date, and helpdesk contact.

### Post-deployment (after Ring 3 soak complete)

Send a completion notice to stakeholders with final success metrics, any issues encountered,
and how they were resolved.

---

## 10. Post-Deployment Tasks

- [ ] Mark change as **Complete** in ITSM (Change ID: ___________________)
- [ ] Confirm final success rate ≥ 98% across all rings in Intune **Device status**
- [ ] Update device configuration documentation / runbook library with profile details
- [ ] Archive Ring AAD groups — rename to `ARCHIVE-Intune-[ChangeID]-RingN` (do **not** delete; useful for future targeting or rollback reference)
- [ ] Schedule a **30-day health check** in Endpoint Analytics to confirm no long-term drift
- [ ] Share lessons learned with the team, especially any ring timing adjustments made during rollout

---

## Appendix: Script Reference

The PowerShell script `scripts/Invoke-IntuneRingAssignment.ps1` is included alongside this runbook.

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-PolicyId` | Yes | GUID of the Intune configuration profile |
| `-GroupId` | Yes | Azure AD group Object ID for the ring |
| `-OldPolicyId` | No | GUID of a prior policy version to exclude the group from (not needed for this deployment — brand new profile) |
| `-WhatIf` | No | Dry-run mode — shows what would happen without making changes |

**Prerequisites:**
```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
```
