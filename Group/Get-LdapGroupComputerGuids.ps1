param(
    [Parameter(Mandatory)]
    [string]$GroupName,

    [string]$SearchBase = ([adsi]"LDAP://RootDSE").defaultNamingContext.ToString()
)

# Resolve the group's distinguishedName first (needed for the matching-rule filter)
$groupSearcher = New-Object System.DirectoryServices.DirectorySearcher
$groupSearcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
$groupSearcher.Filter = "(&(objectCategory=group)(cn=$GroupName))"
$groupSearcher.PropertiesToLoad.Add("distinguishedName") | Out-Null

$groupResult = $groupSearcher.FindOne()
if (-not $groupResult) {
    throw "Group '$GroupName' not found under $SearchBase"
}
$groupDN = $groupResult.Properties["distinguishedname"][0]

# Transitive member search: LDAP_MATCHING_RULE_IN_CHAIN = 1.2.840.113556.1.4.1941
$searcher = New-Object System.DirectoryServices.DirectorySearcher
$searcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
$searcher.Filter = "(&(objectCategory=computer)(member:1.2.840.113556.1.4.1941:=$groupDN))"
$searcher.PropertiesToLoad.Add("objectGUID") | Out-Null
$searcher.PropertiesToLoad.Add("distinguishedName") | Out-Null
$searcher.PageSize = 1000   # required to page past the 1000-item MaxPageSize default

$results = $searcher.FindAll()

$computers = foreach ($r in $results) {
    $guidBytes = $r.Properties["objectguid"][0]
    [PSCustomObject]@{
        DistinguishedName = $r.Properties["distinguishedname"][0]
        ObjectGuid        = [guid]$guidBytes
    }
}

$computers | Format-Table -AutoSize
