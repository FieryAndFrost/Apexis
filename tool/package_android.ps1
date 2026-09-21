$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectDirectory
try {
    flutter build apk --debug
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    $outputDirectory = Join-Path $projectDirectory 'APP'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-debug.apk' -Destination (Join-Path $outputDirectory 'Apexis-debug.apk') -Force
    Write-Output "Development APK: $outputDirectory\Apexis-debug.apk"
} finally {
    Pop-Location
}
