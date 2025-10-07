$newUser = 'hubsroom1@contoso.com'
# Connect (install module if needed: Install-Module ExchangeOnlineManagement)

# Install-Module ExchangeOnlineManagement
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# Create room mailbox
New-Mailbox -MicrosoftOnlineServicesID $newUser -Name "Hub Room 1"`
    -Alias "hubroom1" `
    -Room `
    -EnableRoomMailboxAccount $true `
    -RoomMailboxPassword (ConvertTo-SecureString -String '<pass>' -AsPlainText -Force)

# Calendar for Teams auto-accept
Set-CalendarProcessing -Identity $newUser `
    -AutomateProcessing AutoAccept `
    -AddOrganizerToSubject $false `
    -AllowRecurringMeetings $true `
    -DeleteAttachments $true `
    -DeleteComments $false `
    -DeleteSubject $false `
    -ProcessExternalMeetingMessages $true `
    -RemovePrivateProperty $false `
    -AddAdditionalResponse $true `
    -AdditionalResponse "Welcome to our Surface Hub Teams Room!"

# Booking limits (180 days, no conflicts)
Set-CalendarProcessing -Identity "hubroom@contoso.com" `
    -BookingWindowInDays 180 `
    -MaximumDurationInMinutes 1440 `
    -AllowConflicts $false