<#

generate fake device swith compliance

1,000,000 records
#>

$rpt = [system.collections.generic.list[psobject]]::new()
foreach ($i in 1..1000000){
  # generate fake email
  $email = "$(get-random -min 100 -max 10000 -setseed 500)@jax3.net" 
  $deviceid = (new-guid).guid
  $rpt.add(
  [PSCustomObject]@{
    'Device Id' = $deviceid
    'upn' = $email
  }
  )
}

write-host 'Records generated - export unsorted' -foreground green
$rpt | export-csv -path unsorted.csv -notypeinformation
write-host 'Export sorted'
$rpt | sort-object 'Device Id' | export-csv sorted.csv -notypeinformation
