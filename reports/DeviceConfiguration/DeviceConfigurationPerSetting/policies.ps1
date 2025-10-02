$policies = @(
    '5a334634-cb15-40fa-9c0e-b4bfcf7866f5', # office templates
    'ab90992a-1a91-43d5-b388-ddfb7db4365b'  # bitlocker
)

foreach($stig in $policies){
    ./Get-IntuneConfigurationPerSettingStatus.ps1 -policyId $stig -outputFolder "~/Downloads/Src/PerSetting/"
}