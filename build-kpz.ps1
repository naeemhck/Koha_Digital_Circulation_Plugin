param(
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z.-]*$')]
    [string]$ReleaseSuffix = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$manifest = Join-Path $root 'MANIFEST'
$mainPath = Join-Path $root 'Koha\Plugin\Com\JunaidZaidiLibrary\DigitalCirculation.pm'
$mainSource = Get-Content -Raw -LiteralPath $mainPath
$versionMatch = [regex]::Match($mainSource, 'our\s+\$VERSION\s*=\s*''([^'']+)''')
if (-not $versionMatch.Success) { throw 'Could not determine plugin version from the main module' }
$version = $versionMatch.Groups[1].Value
$artifactSuffix = if ($ReleaseSuffix) { "-$ReleaseSuffix" } else { '' }
$output = Join-Path $root "dist\JunaidZaidiLibrary-DigitalCirculation-v$version$artifactSuffix.kpz"

Push-Location $root
try {
    & (Join-Path $root 'scripts\Validate-Source.ps1')
    New-Item -ItemType Directory -Force (Split-Path $output) | Out-Null
    if (Test-Path $output) {
        throw "Output already exists; preserve or archive it before rebuilding: $output"
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [IO.File]::Open($output, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($relativePath in (Get-Content $manifest | Where-Object { $_ } | Sort-Object)) {
                $sourcePath = Join-Path $root $relativePath
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Missing manifest file: $relativePath"
                }
                $entry = $archive.CreateEntry(
                    $relativePath.Replace('\', '/'),
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = [DateTimeOffset]::new(
                    2026, 7, 23, 0, 0, 0, [TimeSpan]::Zero
                )
                $entryStream = $entry.Open()
                try {
                    $sourceStream = [IO.File]::OpenRead($sourcePath)
                    try { $sourceStream.CopyTo($entryStream) }
                    finally { $sourceStream.Dispose() }
                }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $fileStream.Dispose() }

    & (Join-Path $root 'scripts\Validate-Source.ps1') -Kpz $output
    $archiveRead = [IO.Compression.ZipFile]::OpenRead($output)
    try { $memberCount = $archiveRead.Entries.Count }
    finally { $archiveRead.Dispose() }
    $artifact = Get-Item -LiteralPath $output
    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()

    Write-Output "Artifact: $($artifact.FullName)"
    Write-Output "Bytes: $($artifact.Length)"
    Write-Output "Members: $memberCount"
    Write-Output "SHA-256: $sha256"
}
finally {
    Pop-Location
}
