Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TargetDir = (Get-Location).Path

# VIDEO + AUDIO (NO .ipch, NO random cache)
$ext = @(
    '.mp4','.mkv','.avi','.mov','.wmv','.m4v','.asf','.webm',
    '.m4a','.mp3','.aac','.flac','.wav','.ogg','.opus','.wma'
)

$files = Get-ChildItem -File -Force -Path $TargetDir -Recurse |
    Where-Object { $ext -contains $_.Extension.ToLowerInvariant() }

if (-not $files) { Write-Host "No matching files found."; return }

$sizeGroups = $files | Group-Object Length | Where-Object { $_.Count -ge 2 }
if (-not $sizeGroups) { Write-Host "No duplicate-by-size groups."; return }

Write-Host ""
Write-Host "Scanning for SHA256-confirmed duplicates..."
Write-Host ""

$totalDelete = 0
$totalBytes  = [int64]0
$preview = @()

$sgCount = [int]$sizeGroups.Count
$sgIndex = 0

foreach ($sg in $sizeGroups) {
    $sgIndex++
    $pct = if ($sgCount -gt 0) { [int](100.0 * $sgIndex / $sgCount) } else { 0 }
    if ($pct -gt 100) { $pct = 100 }
    Write-Progress -Activity "Hashing size buckets" -Status "$sgIndex / $sgCount" -PercentComplete $pct

    $hashed = foreach ($fi in $sg.Group) {
        try {
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $fi.FullName -ErrorAction Stop).Hash
            [pscustomobject]@{
                Path      = $fi.FullName
                SizeBytes = [int64]$fi.Length
                LastWrite = $fi.LastWriteTime
                Hash      = $h
            }
        } catch {
            Write-Warning "Hash failed (skipping): $($fi.FullName) :: $($_.Exception.Message)"
        }
    }

    if (-not $hashed) { continue }

    $groups = $hashed | Group-Object Hash | Where-Object { $_.Count -ge 2 }

    foreach ($g in $groups) {
        $items = $g.Group |
            Sort-Object @{e='LastWrite';Descending=$true}, @{e='Path';Descending=$false}

        $keep   = $items[0]
        $delete = $items | Select-Object -Skip 1

        $preview += [pscustomobject]@{
            Hash       = $g.Name
            KeepPath   = $keep.Path
            DeletePath = @($delete | ForEach-Object { $_.Path })
        }

        foreach ($d in $delete) {
            $totalDelete++
            $totalBytes += [int64]$d.SizeBytes
        }
    }
}

Write-Progress -Activity "Hashing size buckets" -Completed

if (-not $preview) { Write-Host "No true duplicates found (SHA256 confirmed)."; return }

Write-Host "================ DRY RUN ================"
$setNum = 0
foreach ($set in $preview) {
    $setNum++
    Write-Host ""
    Write-Host "SET $setNum"
    Write-Host "KEEP: $($set.KeepPath)"
    foreach ($p in $set.DeletePath) { Write-Host "DEL : $p" }
}

Write-Host ""
Write-Host "Would delete $totalDelete file(s), freeing $([math]::Round(([double]$totalBytes / 1MB),2)) MB"
Write-Host "========================================="

$ans = Read-Host "Type DELETE to proceed (anything else cancels)"
if ($ans -ne "DELETE") { Write-Host "Cancelled."; return }

foreach ($set in $preview) {
    foreach ($p in $set.DeletePath) {
        try {
            if (Test-Path -LiteralPath $p) {
                Write-Host "Deleting: $p"
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Delete failed: $p :: $($_.Exception.Message)"
        }
    }
}

Write-Host "Done."
