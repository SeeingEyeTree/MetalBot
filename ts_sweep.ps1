# ts_sweep.ps1 -- run line_sweep.py on TreeServer with the machine kept awake for the duration.
#   powershell -File ts_sweep.ps1 cons2 nano_u05 ...        (config labels from line_sweep.py)
Add-Type -Namespace Win -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[void][Win.Power]::SetThreadExecutionState(0x80000001)      # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
Set-Location $PSScriptRoot
$py = Join-Path $env:LOCALAPPDATA "Python\bin\python.exe"
if (-not (Test-Path $py)) { $py = "python" }
& $py line_sweep.py --n 2 --only @args *> ts_sweep.log
[void][Win.Power]::SetThreadExecutionState(0x80000000)      # release
