# Execute only pure helpers: no AWS, render process, filesystem mutation or stop action.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "Expected Windows PowerShell 5.1, got $($PSVersionTable.PSVersion)"
}
. "$PSScriptRoot/../in-guest/Config.ps1"
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "$Label expected '$Expected', got '$Actual'" }
}
Assert-Equal (Resolve-RenderActive -WorkerActive $true -GpuUtil 0 -Signal WorkerOnly -GpuBusyPercent 15) $true 'active worker'
Assert-Equal (Resolve-RenderActive -WorkerActive $false -GpuUtil 90 -Signal WorkerOnly -GpuBusyPercent 15) $false 'idle worker ignores GPU'
Assert-Equal (Resolve-RenderActive -WorkerActive $false -GpuUtil 90 -Signal WorkerOrGpu -GpuBusyPercent 15) $true 'GPU fallback'
Assert-Equal (Convert-AzToRegion -AvailabilityZone 'us-east-1a') 'us-east-1' 'availability zone'
Assert-Equal (Test-TopazTempFile -Name 'clip_temp.mov' -TempMarker '_temp') $true 'unfinished render'
Assert-Equal (Test-TopazTempFile -Name 'clip.mov' -TempMarker '_temp') $false 'completed render'
Assert-ValidCompletionSignal -Signal WorkerOnly
Assert-ValidStopStrategy -Strategy GuestShutdown
Write-Host 'Windows PowerShell 5.1 production helpers passed.'
