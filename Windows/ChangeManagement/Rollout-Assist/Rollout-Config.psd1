#Requires -Version 5.1
<#
.SYNOPSIS
    Single source of truth for an Intune configuration profile staged rollout.

.DESCRIPTION
    Fill in every field below ONCE.
    Then use:
      - New-RunbookFromConfig.ps1  to generate a fully populated runbook markdown
      - Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber <0-3>
        to execute each ring assignment without repeating GUIDs

    GUIDs are found in:
      - PolicyId / OldPolicyId : Intune portal > Devices > Configuration profiles
                                 > [profile] > Properties > copy from URL or Overview
      - GroupId                : Entra ID > Groups > [group] > Properties > Object ID
#>
@{

    # ── Change metadata ────────────────────────────────────────────────────────
    ChangeId        = 'CHG-2026-NNNN'          # ITSM change request ID
    ChangeTitle     = 'Config Profile Rollout'  # Short human-readable title
    Owner           = 'Jake - Fitaas'        # Change owner name and team
    FleetSize       = 100000                    # Approximate total managed device count

    # ── Policy being deployed ──────────────────────────────────────────────────
    PolicyId        = 'c578f911-e766-444f-be79-6ac0ad6ab40a'    # GUID of the NEW Intune config profile to roll out
    PolicyName      = 'S-Mime-ADMX-Domains'    # Display name exactly as it appears in Intune
    Platform        = 'Windows 10/11'    # e.g. "Windows 10/11", "macOS", "iOS", "Android"
    AssignedVia     = 'Static Group'    # e.g. "Dynamic AAD group", "Static group", "Enrollment filter"

    # Leave OldPolicyId blank ('') if this is a brand-new profile with no predecessor.
    # If you ARE replacing an existing profile, put its GUID here so devices in each
    # ring are excluded from the old profile as they receive the new one.
    OldPolicyId     = '8198f9e9-af13-450a-873e-9003aef95624'

    # ── Deployment rings ───────────────────────────────────────────────────────
    # Each ring needs:
    #   GroupId     - Azure AD group Object ID
    #   GroupName   - Human-readable name (used in runbook and output only)
    #   Description - Label used in runbook table
    #   SoakDays    - Minimum soak period before advancing to the next ring
    Rings = @(
        @{
            Number      = 0
            GroupId     = ''                        # Ring 0 group Object ID
            GroupName   = "Intune-$('CHG-2026-NNNN')-Ring0"
            Description = 'IT / Pilot'
            SoakDays    = 3
        },
        @{
            Number      = 1
            GroupId     = 'b0e69ac2-43ef-4365-a60d-76454cac0523'                        # Ring 1 group Object ID
            GroupName   = "Bitlocker - TC1"
            Description = 'Early Adopters'
            SoakDays    = 7
        },
        @{
            Number      = 2
            GroupId     = ''                        # Ring 2 group Object ID
            GroupName   = "Intune-$('CHG-2026-NNNN')-Ring2"
            Description = 'Limited Broad'
            SoakDays    = 7
        },
        @{
            Number      = 3
            GroupId     = ''                        # Ring 3 group Object ID
            GroupName   = "Intune-$('CHG-2026-NNNN')-Ring3"
            Description = 'Broad'
            SoakDays    = 7
        }
    )

    # ── Contacts ───────────────────────────────────────────────────────────────
    DecisionOwner   = 'Nestor'     # Who calls go/no-go
    EscalationContact = 'Dan'   # Who to escalate Stop conditions to
    RollbackOwner   = 'Jake'     # Who executes rollback if triggered
    HelpdeskContact = 'helpdesk@example.com or Teams channel link'
    ITTeamName      = 'CHL-Intune-Windows'

    # ── Optional: change summary text ─────────────────────────────────────────
    # A 2-4 sentence description of what is being deployed and why.
    # If left blank, the runbook will include a placeholder instead.
    ChangeSummary   = ''
}
