param(
    [string]$LogPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Test-R4BasicPerformanceMarker {
    param([string]$Text)

    $matches = [regex]::Matches(
        $Text,
        '(?im)^R4BASIC performance-workload: name=(numeric|string-assign|string-len|string-ucase|call|array) instructions=(\d+) ticks=(\d+) ips=(\d+) slices=(\d+) maxSlice=(\d+) timeLimited=(\d+) noFixedSleep=(\d+) clockReads=(\d+) maxClockReads=(\d+) nsPerInstruction=(\d+) stringClones=(\d+) stringCloneBytes=(\d+) borrowedBuiltins=(\d+) ownedBuiltins=(\d+) procedureCalls=(\d+) localPoolGrows=(\d+) localPoolReuses=(\d+) localInitializations=(\d+) result=(OK|FAILED)\r?$'
    )
    if ($matches.Count -ne 6) { throw "R4BASIC performance marker set must contain exactly six workloads, found $($matches.Count)." }
    $workloads = @{}
    foreach ($match in $matches) {
        $name = $match.Groups[1].Value.ToLowerInvariant()
        if ($workloads.ContainsKey($name)) { throw "R4BASIC performance workload is duplicated: $name." }
        $record = [pscustomobject]@{
            Name = $name
            Instructions = [uint64]$match.Groups[2].Value
            Ticks = [uint64]$match.Groups[3].Value
            InstructionsPerSecond = [uint64]$match.Groups[4].Value
            Slices = [uint64]$match.Groups[5].Value
            MaximumSlice = [uint64]$match.Groups[6].Value
            TimeLimitedSlices = [uint64]$match.Groups[7].Value
            NoFixedSleep = [uint64]$match.Groups[8].Value
            ClockReads = [uint64]$match.Groups[9].Value
            MaximumClockReads = [uint64]$match.Groups[10].Value
            NanosecondsPerInstruction = [uint64]$match.Groups[11].Value
            StringClones = [uint64]$match.Groups[12].Value
            StringCloneBytes = [uint64]$match.Groups[13].Value
            BorrowedBuiltins = [uint64]$match.Groups[14].Value
            OwnedBuiltins = [uint64]$match.Groups[15].Value
            ProcedureCalls = [uint64]$match.Groups[16].Value
            LocalPoolGrows = [uint64]$match.Groups[17].Value
            LocalPoolReuses = [uint64]$match.Groups[18].Value
            LocalInitializations = [uint64]$match.Groups[19].Value
            Result = $match.Groups[20].Value
        }
        if ($record.Result -ne 'OK') { throw "R4BASIC performance workload reported failure: $name." }
        if ($record.Instructions -eq 0 -or $record.Ticks -eq 0 -or $record.Slices -eq 0 -or $record.InstructionsPerSecond -eq 0) {
            throw "R4BASIC performance counters are empty: $name."
        }
        if ($record.MaximumSlice -gt 4096) { throw "R4BASIC slice $($record.MaximumSlice) exceeds the 4096-instruction contract: $name." }
        if ($record.NoFixedSleep -ne 1) { throw "R4BASIC runnable guest still advertises a fixed wait: $name." }
        if ($record.ClockReads -eq 0 -or $record.MaximumClockReads -gt 17) { throw "R4BASIC clock-read bound is invalid: $name." }
        if ($record.NanosecondsPerInstruction -eq 0) { throw "R4BASIC ns/instruction evidence is empty: $name." }
        $workloads[$name] = $record
    }

    foreach ($name in @('numeric', 'string-assign', 'string-len', 'string-ucase', 'call', 'array')) {
        if (-not $workloads.ContainsKey($name)) { throw "R4BASIC performance workload is missing: $name." }
    }
    if ($workloads['numeric'].InstructionsPerSecond -lt 52000) {
        throw "R4BASIC numeric throughput $($workloads['numeric'].InstructionsPerSecond) instructions/s is below the 52000 instructions/s acceptance floor."
    }
    $assignment = $workloads['string-assign']
    if ($assignment.StringClones -eq 0 -or $assignment.StringCloneBytes -ne $assignment.StringClones * 4096) {
        throw 'R4BASIC string assignment does not report exactly one 4-KB clone per loaded value.'
    }
    foreach ($name in @('string-len', 'string-ucase')) {
        if ($workloads[$name].BorrowedBuiltins -eq 0 -or $workloads[$name].StringClones -ne 0) {
            throw "R4BASIC read-only builtin argument is not borrowed without a string clone: $name."
        }
    }
    $call = $workloads['call']
    if ($call.ProcedureCalls -eq 0 -or $call.LocalPoolGrows -eq 0 -or $call.LocalPoolReuses -eq 0 -or
        ($call.LocalPoolGrows + $call.LocalPoolReuses) -ne $call.ProcedureCalls -or
        $call.LocalInitializations -ne $call.ProcedureCalls) {
        throw 'R4BASIC procedure workload does not preserve the reusable one-local frame contract.'
    }

    $summary = [regex]::Match($Text, '(?im)^R4BASIC performance: numericIps=(\d+) stringAssignIps=(\d+) stringLenIps=(\d+) stringUcaseIps=(\d+) callIps=(\d+) arrayIps=(\d+) result=(OK|FAILED)\r?$')
    if (-not $summary.Success -or $summary.Groups[7].Value -ne 'OK') { throw 'R4BASIC performance summary is missing or failed.' }
    $summaryNames = @('numeric', 'string-assign', 'string-len', 'string-ucase', 'call', 'array')
    for ($index = 0; $index -lt $summaryNames.Count; $index++) {
        if ([uint64]$summary.Groups[$index + 1].Value -ne $workloads[$summaryNames[$index]].InstructionsPerSecond) {
            throw "R4BASIC performance summary differs from workload: $($summaryNames[$index])."
        }
    }
    [pscustomobject]@{ Workloads = $workloads }
}

if ($SelfTest) {
    $valid = @(
        'R4BASIC performance-workload: name=numeric instructions=90000 ticks=1000 ips=90000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1100 stringClones=0 stringCloneBytes=0 borrowedBuiltins=0 ownedBuiltins=0 procedureCalls=0 localPoolGrows=0 localPoolReuses=0 localInitializations=0 result=OK',
        'R4BASIC performance-workload: name=string-assign instructions=80000 ticks=1000 ips=80000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1200 stringClones=100 stringCloneBytes=409600 borrowedBuiltins=0 ownedBuiltins=1 procedureCalls=0 localPoolGrows=0 localPoolReuses=0 localInitializations=0 result=OK',
        'R4BASIC performance-workload: name=string-len instructions=120000 ticks=1000 ips=120000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=800 stringClones=0 stringCloneBytes=0 borrowedBuiltins=1000 ownedBuiltins=1 procedureCalls=0 localPoolGrows=0 localPoolReuses=0 localInitializations=0 result=OK',
        'R4BASIC performance-workload: name=string-ucase instructions=70000 ticks=1000 ips=70000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=1300 stringClones=0 stringCloneBytes=0 borrowedBuiltins=800 ownedBuiltins=1 procedureCalls=0 localPoolGrows=0 localPoolReuses=0 localInitializations=0 result=OK',
        'R4BASIC performance-workload: name=call instructions=100000 ticks=1000 ips=100000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=900 stringClones=0 stringCloneBytes=0 borrowedBuiltins=0 ownedBuiltins=0 procedureCalls=1000 localPoolGrows=1 localPoolReuses=999 localInitializations=1000 result=OK',
        'R4BASIC performance-workload: name=array instructions=110000 ticks=1000 ips=110000 slices=30 maxSlice=4096 timeLimited=2 noFixedSleep=1 clockReads=400 maxClockReads=17 nsPerInstruction=850 stringClones=0 stringCloneBytes=0 borrowedBuiltins=0 ownedBuiltins=0 procedureCalls=0 localPoolGrows=0 localPoolReuses=0 localInitializations=0 result=OK',
        'R4BASIC performance: numericIps=90000 stringAssignIps=80000 stringLenIps=120000 stringUcaseIps=70000 callIps=100000 arrayIps=110000 result=OK'
    ) -join "`r`n"
    $parsed = Test-R4BasicPerformanceMarker -Text $valid
    if ($parsed.Workloads['numeric'].InstructionsPerSecond -ne 90000) { throw 'Valid marker parsed incorrectly.' }
    foreach ($invalid in @(
        $valid.Replace('numeric instructions=90000 ticks=1000 ips=90000', 'numeric instructions=51000 ticks=1000 ips=51000').Replace('numericIps=90000', 'numericIps=51000'),
        $valid.Replace('stringCloneBytes=409600', 'stringCloneBytes=409599'),
        $valid.Replace('name=string-len instructions=120000', 'name=string-len instructions=120000 stringClones=1'),
        $valid.Replace('localPoolReuses=999', 'localPoolReuses=998'),
        $valid.Replace('maxSlice=4096', 'maxSlice=4097'),
        $valid.Replace('arrayIps=110000 result=OK', 'arrayIps=110000 result=FAILED')
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
