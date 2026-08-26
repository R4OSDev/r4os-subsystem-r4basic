param(
    [string]$LogPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Test-R4BasicPerformanceMarker {
    param([string]$Text)

    $match = [regex]::Match(
        $Text,
        'R4BASIC performance: instructions=(\d+) ticks=(\d+) ips=(\d+) slices=(\d+) maxSlice=(\d+) timeLimited=(\d+) noFixedSleep=(\d+) clockReads=(\d+) maxClockReads=(\d+) nsPerInstruction=(\d+) cancelCallbacks=(\d+) metadataReads=(\d+) textSyncChecks=(\d+) cellResolves=(\d+) conversions=(\d+) result=(OK|FAILED)'
    )
    if (-not $match.Success) { throw 'R4BASIC performance marker is missing.' }
    $instructions = [uint64]$match.Groups[1].Value
    $ticks = [uint64]$match.Groups[2].Value
    $ips = [uint64]$match.Groups[3].Value
    $slices = [uint64]$match.Groups[4].Value
    $maximumSlice = [uint64]$match.Groups[5].Value
    $timeLimited = [uint64]$match.Groups[6].Value
    $noFixedSleep = [uint64]$match.Groups[7].Value
    $clockReads = [uint64]$match.Groups[8].Value
    $maximumClockReads = [uint64]$match.Groups[9].Value
    $nanosecondsPerInstruction = [uint64]$match.Groups[10].Value
    $cancelCallbacks = [uint64]$match.Groups[11].Value
    $metadataReads = [uint64]$match.Groups[12].Value
    $textSyncChecks = [uint64]$match.Groups[13].Value
    $cellResolves = [uint64]$match.Groups[14].Value
    $conversions = [uint64]$match.Groups[15].Value
    $result = $match.Groups[16].Value

    if ($result -ne 'OK') { throw 'R4BASIC performance self-test reported failure.' }
    if ($instructions -eq 0 -or $ticks -eq 0 -or $slices -eq 0) { throw 'R4BASIC performance counters are empty.' }
    if ($ips -lt 52000) { throw "R4BASIC throughput $ips instructions/s is below the 52000 instructions/s acceptance floor." }
    if ($maximumSlice -gt 4096) { throw "R4BASIC slice $maximumSlice exceeds the 4096-instruction contract." }
    if ($noFixedSleep -ne 1) { throw 'R4BASIC runnable guest still advertises a fixed wait.' }
    if ($clockReads -eq 0 -or $maximumClockReads -gt 17) { throw 'R4BASIC clock-read bound is missing or exceeds 17 reads per full slice.' }
    if ($nanosecondsPerInstruction -eq 0) { throw 'R4BASIC ns/instruction evidence is empty.' }
    if ($cancelCallbacks -eq 0 -or $cancelCallbacks -ge $instructions) { throw 'R4BASIC cancel callback evidence is not chunk-bounded.' }
    if ($metadataReads -eq 0 -or $metadataReads -ge $instructions) { throw 'R4BASIC cold metadata reads are not statement-bounded.' }
    if ($textSyncChecks -eq 0 -or $textSyncChecks -ge $instructions) { throw 'R4BASIC text sync probes are not boundary-bounded.' }
    if ($cellResolves -eq 0) { throw 'R4BASIC resolved-cell evidence is empty.' }

    [pscustomobject]@{
        Instructions = $instructions
        Ticks = $ticks
        InstructionsPerSecond = $ips
        Slices = $slices
        MaximumSlice = $maximumSlice
        TimeLimitedSlices = $timeLimited
        NoFixedSleep = $true
        ClockReads = $clockReads
        MaximumClockReads = $maximumClockReads
        NanosecondsPerInstruction = $nanosecondsPerInstruction
        CancelCallbacks = $cancelCallbacks
        MetadataReads = $metadataReads
        TextSyncChecks = $textSyncChecks
        CellResolves = $cellResolves
        Conversions = $conversions
    }
}

if ($SelfTest) {
    $valid = 'R4BASIC performance: instructions=90000 ticks=1000 ips=90000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1100 cancelCallbacks=350 metadataReads=12000 textSyncChecks=30 cellResolves=18000 conversions=0 result=OK'
    $parsed = Test-R4BasicPerformanceMarker -Text $valid
    if ($parsed.InstructionsPerSecond -ne 90000) { throw 'Valid marker parsed incorrectly.' }
    foreach ($invalid in @(
        'R4BASIC performance: instructions=51000 ticks=1000 ips=51000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1100 cancelCallbacks=350 metadataReads=12000 textSyncChecks=30 cellResolves=18000 conversions=0 result=OK',
        'R4BASIC performance: instructions=90000 ticks=1000 ips=90000 slices=30 maxSlice=4097 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1100 cancelCallbacks=350 metadataReads=12000 textSyncChecks=30 cellResolves=18000 conversions=0 result=OK',
        'R4BASIC performance: instructions=90000 ticks=1000 ips=90000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=0 clockReads=400 maxClockReads=17 nsPerInstruction=1100 cancelCallbacks=350 metadataReads=12000 textSyncChecks=30 cellResolves=18000 conversions=0 result=OK'
    )) {
        try {
            $null = Test-R4BasicPerformanceMarker -Text $invalid
            throw 'Invalid marker was accepted.'
        } catch {
            if ($_.Exception.Message -eq 'Invalid marker was accepted.') { throw }
        }
    }
    Write-Host 'R4BASIC QEMU performance marker self-test OK.'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($LogPath)) { throw 'LogPath is required.' }
$resolved = (Resolve-Path -LiteralPath $LogPath).Path
$text = [System.IO.File]::ReadAllText($resolved)
Test-R4BasicPerformanceMarker -Text $text
