param([Parameter(Mandatory = $true)][string]$VmServiceUri)
$ErrorActionPreference = 'Stop'
$endpoint = $VmServiceUri -replace '^ws:', 'http:' -replace '^wss:', 'https:' -replace '/ws$', '/'
if (-not $endpoint.EndsWith('/')) { $endpoint += '/' }
$timeline = Invoke-RestMethod -Uri ($endpoint + 'getVMTimeline') -TimeoutSec 15
if ($timeline.error) { throw ($timeline.error | ConvertTo-Json -Compress) }
$pending = @{}
$samples = @{}
foreach ($event in $timeline.result.traceEvents) {
    $duration = $null
    $eventKey = "$($event.tid):$($event.name)"
    if ($event.ph -eq 'B') {
        if (-not $pending.ContainsKey($eventKey)) { $pending[$eventKey] = [System.Collections.Generic.Stack[double]]::new() }
        $pending[$eventKey].Push([double]$event.ts)
    } elseif ($event.ph -eq 'E' -and $pending.ContainsKey($eventKey) -and $pending[$eventKey].Count -gt 0) {
        $duration = ([double]$event.ts - $pending[$eventKey].Pop()) / 1000
    } elseif ($event.ph -eq 'X') {
        $duration = [double]$event.dur / 1000
    }
    if ($null -ne $duration) {
        if (-not $samples.ContainsKey($event.name)) { $samples[$event.name] = [System.Collections.Generic.List[double]]::new() }
        $samples[$event.name].Add($duration)
    }
}
$stats = foreach ($name in $samples.Keys) {
    $values = @($samples[$name] | Sort-Object)
    [PSCustomObject]@{
        name = $name
        count = $values.Count
        p50Ms = [math]::Round($values[[int][math]::Floor(($values.Count - 1) * .5)], 3)
        p95Ms = [math]::Round($values[[int][math]::Floor(($values.Count - 1) * .95)], 3)
        maxMs = [math]::Round($values[-1], 3)
        over16ms = @($values | Where-Object { $_ -gt 16.667 }).Count
    }
}
[ordered]@{
    note = 'Recorded VM timeline event durations, not end-to-end input latency. Debug-mode timings include instrumentation overhead.'
    eventCount = $timeline.result.traceEvents.Count
    phases = @($stats | Where-Object { $_.name -match '^Frame$|^BUILD$|^LAYOUT$|^PAINT$|GPURasterizer::Draw|Animator::BeginFrame|Rasterizer::Draw|Rasterizer::DoDraw' })
    slowestEvents = @($stats | Where-Object { $_.count -ge 5 } | Sort-Object p95Ms -Descending | Select-Object -First 12)
} | ConvertTo-Json -Depth 6
