# At top of script - CONFIGURATION
$hashMB = 10  # MB to hash from start+end. If file < (2*hashMB), does full hash instead

# Replace the SHA256 section with this:
$hashed = foreach ($x in $bg.Group) {
    $filePath = $x.FI.FullName
    $fileSizeMB = $x.FI.Length / 1MB
    $chunkSize = $hashMB * 1MB
    
    # If file is smaller than 2x chunk size, just hash the whole thing
    if ($fileSizeMB -lt ($hashMB * 2)) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash
    }
    else {
        # Hash first chunk + last chunk
        $fs = [System.IO.File]::OpenRead($filePath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        
        # Read first chunk
        $firstChunk = New-Object byte[] $chunkSize
        [void]$fs.Read($firstChunk, 0, $chunkSize)
        
        # Seek to last chunk
        $fs.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
        $lastChunk = New-Object byte[] $chunkSize
        [void]$fs.Read($lastChunk, 0, $chunkSize)
        
        $fs.Close()
        
        # Combine and hash
        $combined = $firstChunk + $lastChunk
        $hashBytes = $sha256.ComputeHash($combined)
        $h = [BitConverter]::ToString($hashBytes) -replace '-'
        $sha256.Dispose()
    }
    
    [pscustomobject]@{
        FI        = $x.FI
        Duration  = $x.Duration
        DurBucket = $x.DurBucket
        Hash      = $h
    }
}
What this does:

$hashMB = 10 → checks first 10MB + last 10MB
If file < 20MB → does full SHA256 instead
No stupid scenarios where it tries to hash 118MB of a 100MB file

User sets it once at top, done.fullscript1:56 AMpowershell# Operate on the directory you CALL the script from
$TargetDir = (Get-Location).Path
Write-Host "Operating on directory:`n$TargetDir`n"

# Video extensions
$ext = @('.mp4','.mkv','.avi','.mov','.wmv','.m4v','.asf','.webm')

# Duration bucket seconds (50ms). Raise to 0.1/0.25 if needed.
$durBucket = 0.05

# Corruption probe seconds (fast spot-check)
$probeSec = 2.0

# Hash configuration: MB to check at start+end. If file < (2*hashMB), does full hash.
$hashMB = 10

function Get-DurationSec([string]$f) {
    $durText = & ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 $f 2>$null
    $dur = 0.0
    [void][double]::TryParse(($durText | Select-Object -First 1), [ref]$dur)
    return $dur
}

function Get-ErrCount([string]$f, [double]$ss, [double]$t) {
    $log = & ffmpeg -hide_banner -v error -ss $ss -t $t -i $f -map 0 -f null - 2>&1
    return ($log | Measure-Object).Count
}

function ScoreCorruptionFast([System.IO.FileInfo]$fi, [double]$dur) {
    $f = $fi.FullName

    if ($dur -le 0) {
        return [pscustomobject]@{
            File          = $f
            SizeBytes     = $fi.Length
            SizeMB        = [math]::Round($fi.Length / 1MB, 2)
            DurationSec   = 0.0
            TotalErr      = 999999
            Status        = 'NO_DUR'
            LastWriteTime = $fi.LastWriteTime
        }
    }

    $err = 0

    # Start
    $err += Get-ErrCount $f 0 $probeSec

    # Middle
    if ($dur -gt (2*$probeSec + 2)) {
        $mid = [math]::Max(0, ($dur/2) - ($probeSec/2))
        $err += Get-ErrCount $f $mid $probeSec
    }

    # End
    if ($dur -gt ($probeSec + 2)) {
        $end = [math]::Max(0, $dur - $probeSec)
        $err += Get-ErrCount $f $end $probeSec
    }

    $status =
        if ($err -eq 0) { 'OK' }
        elseif ($err -le 2) { 'Minor' }
        elseif ($err -le 10) { 'Moderate' }
        else { 'Severe' }

    [pscustomobject]@{
        File          = $f
        SizeBytes     = $fi.Length
        SizeMB        = [math]::Round($fi.Length / 1MB, 2)
        DurationSec   = [math]::Round($dur, 3)
        TotalErr      = $err
        Status        = $status
        LastWriteTime = $fi.LastWriteTime
    }
}

# 1) Files in current directory only
$files =
    Get-ChildItem -File -Path $TargetDir |
    Where-Object { $ext -contains $_.Extension.ToLowerInvariant() }

if (-not $files) {
    Write-Host "No video files found."
    return
}

# 2) Candidate groups by exact size (2+)
$sizeGroups =
    $files |
    Group-Object Length |
    Where-Object { $_.Count -ge 2 } |
    Sort-Object { [int64]$_.Name }

if (-not $sizeGroups) {
    Write-Host "No duplicate-by-size groups (2+ files with identical byte size)."
    return
}

# 3) Build dupe sets: size -> duration bucket -> SHA256 -> (2+)
$dupeSets = New-Object System.Collections.Generic.List[object]

foreach ($sg in $sizeGroups) {
    $sizeBytes = [int64]$sg.Name
    $candidates = $sg.Group

    # Get duration (ffprobe) for each file in this size group
    $withDur = foreach ($fi in $candidates) {
        $dur = Get-DurationSec $fi.FullName
        $bucket = if ($dur -gt 0) { ([math]::Round($dur / $durBucket) * $durBucket) } else { -1.0 }

        [pscustomobject]@{
            FI        = $fi
            Duration  = $dur
            DurBucket = $bucket
        }
    }

    # Split by duration bucket
    $bucketGroups = $withDur | Group-Object DurBucket
    foreach ($bg in $bucketGroups) {
        if ($bg.Count -lt 2) { continue } # not dupes by duration

        # Compute SHA256 (partial or full based on file size)
        $hashed = foreach ($x in $bg.Group) {
            $filePath = $x.FI.FullName
            $fileSizeMB = $x.FI.Length / 1MB
            $chunkSize = $hashMB * 1MB
            
            # If file is smaller than 2x chunk size, just hash the whole thing
            if ($fileSizeMB -lt ($hashMB * 2)) {
                $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash
            }
            else {
                # Hash first chunk + last chunk
                $fs = [System.IO.File]::OpenRead($filePath)
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                
                # Read first chunk
                $firstChunk = New-Object byte[] $chunkSize
                [void]$fs.Read($firstChunk, 0, $chunkSize)
                
                # Seek to last chunk
                $fs.Seek(-$chunkSize, [System.IO.SeekOrigin]::End) | Out-Null
                $lastChunk = New-Object byte[] $chunkSize
                [void]$fs.Read($lastChunk, 0, $chunkSize)
                
                $fs.Close()
                
                # Combine and hash
                $combined = $firstChunk + $lastChunk
                $hashBytes = $sha256.ComputeHash($combined)
                $h = [BitConverter]::ToString($hashBytes) -replace '-'
                $sha256.Dispose()
            }
            
            [pscustomobject]@{
                FI        = $x.FI
                Duration  = $x.Duration
                DurBucket = $x.DurBucket
                Hash      = $h
            }
        }

        # Now group by hash (true dupes)
        $hashGroups = $hashed | Group-Object Hash
        foreach ($hg in $hashGroups) {
            if ($hg.Count -lt 2) { continue }

            $dupeSets.Add([pscustomobject]@{
                SizeBytes = $sizeBytes
                DurBucket = [double]$bg.Name
                Hash      = $hg.Name
                Items     = $hg.Group
            }) | Out-Null
        }
    }
}

if (-not $dupeSets -or $dupeSets.Count -eq 0) {
    Write-Host "No duplicate sets found after size + duration + SHA256. Nothing to delete."
    return
}

# 4) For each dupe set, corruption check to pick best keep + delete rest
$plan = New-Object System.Collections.Generic.List[object]

foreach ($ds in $dupeSets) {
    $scored = foreach ($x in $ds.Items) {
        ScoreCorruptionFast $x.FI $x.Duration
    }

    # Winner: least errors, then newest, then path (stable)
    $winner = $scored | Sort-Object TotalErr, @{e='LastWriteTime';Descending=$true}, File | Select-Object -First 1
    $losers = $scored | Where-Object { $_.File -ne $winner.File }

    $plan.Add([pscustomobject]@{
        SizeBytes = $ds.SizeBytes
        SizeMB    = [math]::Round($ds.SizeBytes / 1MB, 2)
        DurBucket = $ds.DurBucket
        Hash      = $ds.Hash
        Winner    = $winner
        Losers    = $losers
    }) | Out-Null
}

# 5) DRY RUN report
Write-Host ""
Write-Host "==================== DRY RUN (NO DELETES) ===================="

$totalDeleteCount = 0
$totalDeleteBytes = 0
$gnum = 0

foreach ($p in $plan) {
    if (-not $p.Losers -or $p.Losers.Count -eq 0) { continue }
    $gnum++

    Write-Host ""
    Write-Host ("=== SET {0}: Size={1} bytes ({2} MB), DurBucket~{3}s, SHA256={4} ===" -f $gnum, $p.SizeBytes, $p.SizeMB, $p.DurBucket, $p.Hash)

    $w = $p.Winner
    Write-Host ("WINNER (KEEP): Err={0}  Dur={1}s  SizeMB={2}  Status={3}" -f $w.TotalErr, $w.DurationSec, $w.SizeMB, $w.Status)
    Write-Host ("  {0}" -f $w.File)

    Write-Host ""
    Write-Host "WILL DELETE:"
    foreach ($d in $p.Losers) {
        Write-Host ("  Err={0}  Dur={1}s  SizeMB={2}  Status={3}" -f $d.TotalErr, $d.DurationSec, $d.SizeMB, $d.Status)
        Write-Host ("    {0}" -f $d.File)

        $totalDeleteCount++
        $totalDeleteBytes += [int64]$d.SizeBytes
    }
}

Write-Host ""
Write-Host ("SUMMARY: would delete {0} file(s), freeing ~{1} MB" -f $totalDeleteCount, [math]::Round($totalDeleteBytes / 1MB, 2))
Write-Host "=============================================================="

# 6) Ask to run for real
$ans = Read-Host "Run for real and DELETE the files listed above? (Y/N)"
if ($ans -notmatch '^(?i)y$') {
    Write-Host "Cancelled. No files were deleted."
    return
}

# 7) Execute deletions
Write-Host ""
Write-Host "==================== DELETING NOW ===================="

foreach ($p in $plan) {
    foreach ($d in $p.Losers) {
        if (Test-Path -LiteralPath $d.File) {
            Write-Host ("Deleting: {0}" -f $d.File)
            Remove-Item -LiteralPath $d.File -Force
        }
    }
}
