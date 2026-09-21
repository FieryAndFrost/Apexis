param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateRange(1,300)][int]$Seconds = 120
)
$ErrorActionPreference = 'Stop'
$ports = @(Get-PnpDevice -PresentOnly -Class Ports | Where-Object { $_.InstanceId -match '^USB\\VID_3654&PID_79B8&MI_01\\' })
if ($ports.Count -ne 1 -or $ports[0].FriendlyName -notmatch '\((COM\d+)\)') { throw 'Expected one DEBUG CDC port' }
$portName = $Matches[1]
$stream = [IO.File]::Open([IO.Path]::GetFullPath($OutputPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$uart = [IO.Ports.SerialPort]::new($portName, 3000000, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$uart.ReadTimeout = 200
$uart.DtrEnable = $true
$count = 0
try {
    $uart.Open()
    Write-Output "Capture ready: $portName, 3000000 baud, RX only, $Seconds seconds"
    $buffer = [byte[]]::new(8192)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        try { $n = $uart.Read($buffer, 0, $buffer.Length) } catch [TimeoutException] { continue }
        if ($n -gt 0) { $stream.Write($buffer, 0, $n); $stream.Flush(); $count += $n }
    }
} finally {
    if ($uart.IsOpen) { $uart.Close() }
    $uart.Dispose()
    $stream.Dispose()
    Write-Output "Capture finished: $count bytes, $OutputPath"
}
