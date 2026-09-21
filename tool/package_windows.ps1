$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectDirectory
try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    $sourceDirectory = Join-Path $projectDirectory 'build\windows\x64\runner\Release'
    foreach ($item in @('apexis.exe', 'flutter_windows.dll', 'data')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $item))) { throw "Missing build artifact: $item" }
    }
    $outputDirectory = Join-Path $projectDirectory 'APP\Apexis'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceDirectory | Copy-Item -Destination $outputDirectory -Recurse -Force
    Write-Output "Windows application: $outputDirectory\apexis.exe"
    Write-Output 'Distribute the complete Apexis directory, including DLLs and data.'
} finally {
    Pop-Location
}
