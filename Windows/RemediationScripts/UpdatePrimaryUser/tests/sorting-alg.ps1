$source = import-csv ./unsorted.csv 
$devices = import-csv ./sorted.csv

$sorted = @()
foreach($i in 1..100){
   $sorted += $source[(get-random -min 0 -max 999999)] 
}

<#
$start = get-date
foreach($i in $sorted){
    $x = $devices | ? 'Device id' -eq $i.'device id'
    if($null -notlike $x){
        write-host 'Found Device'
      }
  }

$stop = get-date

$stop - $start
#>


<# searching unsorted list for 10 items: 
Days              : 0
Hours             : 0
Minutes           : 1
Seconds           : 0
Milliseconds      : 798
Ticks             : 607984547
TotalDays         : 0.000703685818287037
TotalHours        : 0.0168884596388889
TotalMinutes      : 1.01330757833333
TotalSeconds      : 60.7984547
TotalMilliseconds : 60798.4547
#>

$start = get-date 
$prefixIndex = [ordered]@{}
for ($i = 0; $i -lt $devices.Count; $i++) {
    $prefix = $devices[$i].'Device ID'.Substring(0, 4).ToLowerInvariant()

    if ($prefixIndex.Contains($prefix)) {
        $prefixIndex[$prefix].lastLoc = $i
    }
    else {
        $prefixIndex[$prefix] = [pscustomobject]@{ firstLoc = $i; lastLoc = $i }
    }
}

#write-output $prefixIndex
foreach($device in $sorted){
  $deviceId = $device.'Device Id'
  $bucket = $prefixIndex[$deviceId.Substring(0,4).ToLowerInvariant()]
  if ($bucket) {
      $match = $devices[$bucket.firstLoc..$bucket.lastLoc] |
          Where-Object { 
             $_.'Device ID' -eq $deviceId 
          }
      if($match){
        # write-host "Found: $match"
      }
  }
}
$stop = get-date
$stop - $start

<# searching 100,000 items: 
Days              : 0
Hours             : 0
Minutes           : 0
Seconds           : 43
Milliseconds      : 987
Ticks             : 439879856
TotalDays         : 0.000509120203703704
TotalHours        : 0.0122188848888889
TotalMinutes      : 0.733133093333333
TotalSeconds      : 43.9879856
TotalMilliseconds : 43987.9856
#>
