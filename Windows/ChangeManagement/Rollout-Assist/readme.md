How to use this.

Add/update parameters in Rollout-Config.psd1
Then execute New-RunbookFromConfig.ps1 to create a markdown file to add to change request. This will include rollout phases, group id's, rollback etc.

Then to rollout, use the same config file but w/ the Invoke-IntuneRingAssignment.ps1 to rolloout.  Instructions included in the runbook.md file.