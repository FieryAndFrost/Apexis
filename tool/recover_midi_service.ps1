$ErrorActionPreference = 'Stop'
$logPath = Join-Path (Split-Path -Parent $PSScriptRoot) ('artifacts\midi-service-recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Start-Transcript -LiteralPath $logPath -NoClobber | Out-Null
try {
    $service = Get-CimInstance Win32_Service -Filter "Name='midisrv'"
    $service | Select-Object Name, State, ProcessId, PathName, ServiceType | Format-List
    if ($service.ServiceType -ne 'Own Process' -or
        $service.PathName -ine 'C:\Windows\system32\midisrv.exe') {
        throw 'Unexpected service identity. No changes made.'
    }
    if ($service.State -eq 'Running') {
        & sc.exe stop midisrv
        if ($LASTEXITCODE -ne 0) { throw 'Service stop request failed.' }
    }
    $controller = Get-Service -Name midisrv
    try {
        $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
    } catch [System.ServiceProcess.TimeoutException] {
        $service = Get-CimInstance Win32_Service -Filter "Name='midisrv'"
        if ($service.State -ne 'Stop Pending' -or $service.ProcessId -le 0 -or
            $service.ServiceType -ne 'Own Process' -or
            $service.PathName -ine 'C:\Windows\system32\midisrv.exe') {
            throw 'Service identity or state changed. Refusing forced stop.'
        }
        $process = Get-Process -Id $service.ProcessId
        if ($process.ProcessName -ine 'MidiSrv') { throw 'Service PID mismatch.' }
        Write-Output "Stopping only stalled MidiSrv PID $($process.Id)"
        Stop-Process -Id $process.Id -Force
        $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
    }
    Start-Service -Name midisrv
    $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
    Get-CimInstance Win32_Service -Filter "Name='midisrv'" |
        Select-Object Name, State, ProcessId | Format-List
    Write-Output 'MIDI_SERVICE_RECOVERY_OK'
} catch {
    Write-Output "MIDI_SERVICE_RECOVERY_FAILED: $_"
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
