<# 
    Bitlocker detect for systems with either 
    HKLM:\SOFTWARE\Policies\Microsoft\FVE
    TPMPIN  :   1
    TPMKEY  :   1

    If either/both of above are set to 1, report back to intune the values along with an error.
#>

$regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
$flagged = $false
$returnString = "" # to be populated if reg values exist for two key items

if(Test-Path $regPath){
    #path exists, load key
    try {
        $regKey = Get-Item $regPath -ErrorAction Stop
        # check for items TPMPIN / TPMKey flag for value 1
        if ($regKey.GetValueNames().Contains('UseTPMPIN')){
            if($regKey.GetValue('UseTPMPIN') -eq 1){
                $flagged = $true
                $returnString = 'UseTpmPin == 1'
            }
        }
        if($regKey.GetValueNames().Contains('UseTPMKey')){
            if($regKey.GetValue('UseTPMKey') -eq 1){
                if($flagged -ne $true){$flagged = $true}
                if($null -like $returnString){
                    $returnString = "UseTpmKey == 1"
                }else{
                    $returnString = "$returnString , UseTpmKey == 1"
                }
            }
        }
    }
    catch{
        Write-Output "Could not load reg hive $_"
        exit 401
    }
}

if($flagged){
    Write-Output $returnString
    exit 1
}else{
    Write-Output 'Exit 0'
    # exit 0
}
