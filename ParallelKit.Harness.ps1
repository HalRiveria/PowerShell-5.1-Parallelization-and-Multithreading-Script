# Test harness for ParallelKit.ps1. Real runspaces and real child processes
# (cmd.exe / ping.exe), nothing mocked.
#
#   powershell -NoProfile -File .\ParallelKit.Harness.ps1
#
# Exit code 0 = all passed, 1 = any failed.

$ErrorActionPreference = "Stop"
# The whole suite runs under strict mode: a host project may well use it,
# and the kit must not depend on lenient hashtable/variable reads.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ParallelKit.ps1")

$script:passCount = 0
$script:failCount = 0

function Test-Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passCount++
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
    }
}

# Every message the kit emits lands here instead of on the console.
$script:messages = [System.Collections.Generic.List[hashtable]]::new()
$messageSink = $script:messages
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()

function Reset-Harness {
    Reset-PkAbortState
    $script:messages.Clear()
}

function New-JobList {
    param([hashtable[]]$Jobs)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($j in $Jobs) { $list.Add($j) }
    return ,$list
}

$cmdExe  = Join-Path $env:SystemRoot "System32\cmd.exe"
$pingExe = Join-Path $env:SystemRoot "System32\ping.exe"

# A user function the workers share.
function Get-HarnessDouble {
    param([int]$Value)
    return ($Value * 2)
}

# ==============================================================================
Write-Host "=== A: setup ===" -ForegroundColor Cyan
$init = Initialize-ParallelKit -MaxConcurrentProcesses 8
Test-Assert ($init.AbortHandler -eq $true)    "abort handler registers"
Test-Assert ($init.ChildProcessJob -eq $true) "child-process job object initializes"
Test-Assert ($init.ThreadPool -eq $true)      "thread pool minimum is raised"
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 128) "thread pool minimum is at least 128 worker threads"
Write-Host ""

# ==============================================================================
Write-Host "=== B: runspace jobs - results, concurrency cap, messages, shared functions ===" -ForegroundColor Cyan
Reset-Harness
$track = @{ Cur = 0; Max = 0 }
$gate  = [object]::new()
$worker = {
    param([int]$Id, $Track, $Gate)
    [System.Threading.Monitor]::Enter($Gate)
    try { $Track.Cur++; if ($Track.Cur -gt $Track.Max) { $Track.Max = $Track.Cur } } finally { [System.Threading.Monitor]::Exit($Gate) }
    [System.Threading.Thread]::Sleep(300)
    [System.Threading.Monitor]::Enter($Gate)
    try { $Track.Cur-- } finally { [System.Threading.Monitor]::Exit($Gate) }
    Write-PkMessage ("worker " + $Id + " done")
    return @{ Id = $Id; Doubled = (Get-HarnessDouble -Value $Id) }
}
$jobs = New-JobList -Jobs @(1..8 | ForEach-Object { @{ Id = $_; Track = $track; Gate = $gate } })
$results = [System.Collections.Generic.List[hashtable]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript $worker -JobParams $jobs -MaxParallel 3 -SharedFunctionNames @('Get-HarnessDouble') `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -CheckWorkerSafety
Test-Assert ($results.Count -eq 8) "all 8 jobs return a result"
$sum = 0; foreach ($r in $results) { $sum += $r.Doubled }
Test-Assert ($sum -eq 72) "the shared user function ran inside the workers (sum of doubles = 72)"
Test-Assert ($track.Max -le 3 -and $track.Max -ge 2) ("never more than MaxParallel workers at once (peak " + $track.Max + ")")
Test-Assert (@($script:messages | Where-Object { $_.Message -like 'worker * done' }).Count -eq 8) "all 8 worker messages reach the main-thread handler"
Test-Assert ($out.CrashedCount -eq 0 -and -not $out.Aborted -and $out.ForceStoppedCount -eq 0) "a clean run reports no crashes, no abort, nothing force-stopped"
Test-Assert ([PkState]::SourceCount -eq 0) "the run's own cancellation source is unregistered afterwards"
Write-Host ""

# ==============================================================================
Write-Host "=== C: runspace jobs - lazy provider, crash handling, bad input ===" -ForegroundColor Cyan
Reset-Harness
$feed = @{ Next = 1 }
$provider = { if ($feed.Next -gt 5) { return $null }; $j = @{ Id = $feed.Next }; $feed.Next++; return $j }.GetNewClosure()
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) return $Id } -NextJobProvider $provider -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 5) "-NextJobProvider feeds jobs until it returns null"

$crashes = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$jobs = New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) if ($Id -eq 2) { throw "boom" }; return $Id } -JobParams $jobs -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -JobCrashedHandler { param($e) $crashes.Add($e) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 1 -and $crashes.Count -eq 1) "a worker that throws is counted and reported to -JobCrashedHandler"
Test-Assert ($results.Count -eq 2) "the other workers still return their results"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like '*boom*' }).Count -eq 1) "the crash is reported as an Error message"

$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -SharedFunctionNames @('No-SuchFunction') } catch { $threw = ($_.ToString() -like "*No-SuchFunction*") }
Test-Assert $threw "an unknown -SharedFunctionNames entry fails up front with the name in the message"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams (New-JobList -Jobs @(@{ Id = 1; Extra = 2 })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*Extra*") }
Test-Assert $threw "a job key the worker doesn't declare fails with a clear message"
$emptyOut = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams ([System.Collections.Generic.List[hashtable]]::new()) -MaxParallel 1
Test-Assert ($emptyOut.CrashedCount -eq 0 -and -not $emptyOut.Aborted) "an empty job list returns immediately"
Write-Host ""

# ==============================================================================
Write-Host "=== D: runspace jobs - abort ===" -ForegroundColor Cyan
Reset-Harness
# Cooperative workers: stop as soon as they see the cancel.
$worker = {
    param([int]$Id, $CancelToken)
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-PkCancelRequested) { return @{ Id = $Id; Stopped = $true; TokenSeen = ($CancelToken -is [System.Threading.CancellationToken] -and $CancelToken.CanBeCanceled) } }
        [System.Threading.Thread]::Sleep(100)
    }
    return @{ Id = $Id; Stopped = $false }
}
$jobs = New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })
$results = [System.Collections.Generic.List[hashtable]]::new()
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript $worker -JobParams $jobs -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 5) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.Aborted -eq $true) "an abort mid-run is reported as Aborted"
Test-Assert ($results.Count -eq 2) ("only the 2 in-flight workers ran; the other 4 never started (got " + $results.Count + ")")
Test-Assert (@($results | Where-Object { $_.Stopped }).Count -eq 2) "in-flight workers saw the cancel and stopped early"
Test-Assert (@($results | Where-Object { $_.TokenSeen }).Count -eq 2) "a declared `$CancelToken parameter receives the run's token"
Test-Assert ($out.ForceStoppedCount -eq 0) "cooperative workers are not force-stopped"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 8) ("the run ends promptly after the abort (" + [int]$sw.Elapsed.TotalSeconds + "s)")
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Ctrl+C detected*' }).Count -eq 1) "the abort is announced exactly once"
Test-Assert ([PkConsoleCtrl]::DrainComplete.IsSet) "the native handler thread is released after the drain"

# A worker that ignores the cancel gets force-stopped after the drain timeout.
Reset-Harness
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) [System.Threading.Thread]::Sleep(6000); return $Id } `
    -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) -MaxParallel 2 -DrainTimeoutSeconds 1 `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.ForceStoppedCount -eq 2) "workers that ignore the cancel are force-stopped after the drain timeout"
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Force-stopping 2 job(s)*' }).Count -eq 1) "the force-stop is announced"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 4) ("force-stopped workers are abandoned, not waited for (took " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s; the workers sleep 6s)")
Write-Host ""

# ==============================================================================
Write-Host "=== E: single processes ===" -ForegroundColor Cyan
Reset-Harness
$r = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c echo hello& echo oops 1>&2& exit 3'
Test-Assert ($r.ExitCode -eq 3) "exit code is captured"
Test-Assert ($r.Stdout.Trim() -eq 'hello') "stdout is captured"
Test-Assert ($r.Stderr.Trim() -eq 'oops') "stderr is captured"
$threw = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 800 } catch { $threw = ($_.ToString() -like '*did not exit within*') }
$sw.Stop()
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 6) "a process that overruns its time limit is killed and reported"
$threw = $false
try { $null = Start-PkProcess -FilePath 'C:\no\such\program.exe' } catch { $threw = ($_.ToString() -like "*could not start*") }
Test-Assert $threw "a program that can't be started throws a clear error (not a silent null)"
$j = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 0'
$null = Wait-PkProcess -Process $j.Proc -TimeoutMs 5000
Test-Assert ([PkChildProcessJob]::Assign($j.Proc) -or $j.Proc.HasExited) "started processes are tied to the job object"
$j.Proc.Dispose()
Write-Host ""

# ==============================================================================
Write-Host "=== F: process batch ===" -ForegroundColor Cyan
Reset-Harness
$commands = @(0..5 | ForEach-Object { @{ FilePath = $cmdExe; Arguments = ('/c echo item' + $_ + '& exit ' + $_); Tag = $_ } })
$commands += @{ FilePath = 'C:\no\such\program.exe'; Arguments = ''; Tag = 99 }
$seen = [System.Collections.Generic.List[int]]::new()
$batch = Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 3 -OnComplete { param($c, $r) $seen.Add($c.Tag) }.GetNewClosure()
Test-Assert ($batch.Results.Count -eq 7) "every command gets a result"
$byTag = @{}; foreach ($r in $batch.Results) { $byTag[$r.Command.Tag] = $r }
Test-Assert ($byTag[4].ExitCode -eq 4 -and $byTag[4].Stdout.Trim() -eq 'item4') "each result carries its own command, exit code and output"
Test-Assert ($null -eq $byTag[99].ExitCode -and $byTag[99].StartError) "a command that can't start is reported, not dropped"
Test-Assert ($seen.Count -eq 6) "-OnComplete fires for each command that ran"
Test-Assert (-not $batch.Aborted) "a clean batch is not marked aborted"
$wd = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c cd'; WorkingDirectory = $env:SystemRoot }) -MaxConcurrent 1
Test-Assert ($wd.Results[0].Stdout.Trim() -ieq $env:SystemRoot) "a command's WorkingDirectory is honored"
# A foreach over nothing yields $null, not an empty array - the usual way to build the list when no files match.
$noCommands = foreach ($x in @()) { @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }
$emptyBatch = $null
try { $emptyBatch = Invoke-PkProcessBatch -Commands $noCommands -MaxConcurrent 2 } catch { Write-Host "  empty batch threw: $_" }
Test-Assert ($null -ne $emptyBatch -and $emptyBatch.Results.Count -eq 0 -and -not $emptyBatch.Aborted) "a batch given `$null (an empty foreach) returns no results"
Write-Host ""

# ==============================================================================
Write-Host "=== G: process dispatch - groups, limits, retries ===" -ForegroundColor Cyan
Reset-Harness
# 4 groups: 3 jobs, 0 jobs, 2 jobs, 1 job (which is retried once).
$groupDefs = @(
    @{ Name = 'g1'; Count = 3 }, @{ Name = 'g2'; Count = 0 }, @{ Name = 'g3'; Count = 2 }, @{ Name = 'g4'; Count = 1; Retry = $true }
)
$feed = @{ Index = 0 }
$track = @{ Max = 0; Finalized = 0; Retried = 0 }
$completed = [System.Collections.Generic.List[string]]::new()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge $groupDefs.Count) { return $null }; $g = $groupDefs[$feed.Index]; $feed.Index++; return $g }.GetNewClosure() `
    -JobBuilder {
        param($group)
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        for ($i = 0; $i -lt $group.Count; $i++) { $jobs.Add(@{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1'; Retry = [bool]$group.Retry }) }
        return $jobs
    }.GetNewClosure() `
    -AbortPollCallback { param($running) if ($running.Count -gt $track.Max) { $track.Max = $running.Count } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $r = Complete-PkProcess -Job $job
        if ($job.Retry) {
            $track.Retried++
            $pending.Enqueue(@{ FilePath = $pingExe; Arguments = '-n 1 127.0.0.1'; Retry = $false; GroupKey = $job.GroupKey })
            return @{ Requeued = $true }
        }
        $track.Finalized++
        return @{ Success = ($r.ExitCode -eq 0) }
    }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $completed.Add($group.Name) }.GetNewClosure()
Test-Assert ($track.Finalized -eq 6) ("all 6 jobs are finalized, the retried one once (got " + $track.Finalized + ")")
Test-Assert ($track.Retried -eq 1) "a job that returns Requeued is run again"
Test-Assert ($track.Max -eq 2) ("never more than MaxConcurrent processes at once (peak " + $track.Max + ")")
Test-Assert ($completed.Count -eq 4 -and ($completed -contains 'g2')) "every group completes, including the zero-job one"
Test-Assert ($completed.IndexOf('g4') -eq 3) "a group with a requeued job completes only after the retry finishes"
Test-Assert ($dispatch.GroupResults.Count -eq 4 -and -not $dispatch.Aborted) "one result per group, not aborted"
Test-Assert ([PkState]::SourceCount -eq 0) "the dispatcher's own cancellation source is unregistered afterwards"

# A job that can't start is counted and its group still completes.
Reset-Harness
$feed = @{ Given = $false }
$completed = [System.Collections.Generic.List[string]]::new()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'bad' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = 'C:\no\such\program.exe'; Arguments = '' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -GroupCompleteCallback { param($group) $completed.Add($group.Name) }.GetNewClosure()
Test-Assert ($dispatch.JobStarterFailedCount -eq 1) "a job that fails to start is counted"
Test-Assert ($completed.Count -eq 1) "its group still completes once the other job finishes"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like '*JobStarter failed*' }).Count -eq 1) "the start failure is reported as an Error message"

foreach ($bad in @(0, -1, 'x')) {
    $threw = $false
    try { $null = Invoke-PkProcessDispatch -MaxConcurrent $bad -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) } } catch { $threw = ($_.ToString() -like '*-MaxConcurrent must be*') }
    Test-Assert $threw ("-MaxConcurrent '" + $bad + "' is refused up front instead of spinning forever")
}
$threw = $false
try { $null = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 0 -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) } } catch { $threw = ($_.ToString() -like '*-MaxQueueAhead must be*') }
Test-Assert $threw "-MaxQueueAhead 0 is refused up front"

# Zero-job groups hold their queue-ahead slot until released.
Reset-Harness
$feed = @{ Index = 0 }
$released = [System.Collections.Generic.HashSet[int]]::new()
$pulledAtFirstRelease = @{ Value = -1 }
$ticks = @{ Count = 0 }
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge 6) { return $null }; $g = @{ Id = $feed.Index }; $feed.Index++; return $g }.GetNewClosure() `
    -JobBuilder { param($g) return @() } `
    -JobFinalize { param($job, $pending) } `
    -GroupReleaseCheck { param($g) return $released.Contains($g.Id) }.GetNewClosure() `
    -AbortPollCallback {
        param($running)
        $ticks.Count++
        if ($ticks.Count -eq 4) { $pulledAtFirstRelease.Value = $feed.Index }
        if ($ticks.Count -ge 4) { for ($i = 0; $i -lt 6; $i++) { $null = $released.Add($i) } }
    }.GetNewClosure()
Test-Assert ($pulledAtFirstRelease.Value -eq 2) ("with -GroupReleaseCheck, zero-job groups can't run ahead of MaxQueueAhead (pulled " + $pulledAtFirstRelease.Value + " before release)")
Test-Assert ($dispatch.GroupResults.Count -eq 6) "all groups complete once released"
Write-Host ""

# ==============================================================================
Write-Host "=== H: process dispatch - abort ===" -ForegroundColor Cyan
Reset-Harness
$feed = @{ Given = $false }
$cleaned = @{ Count = 0 }
$ticks = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 -AbortTimeoutSeconds 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'slow' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(1..5 | ForEach-Object { @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' } }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -JobAbortCleanup { param($job) $cleaned.Count++ }.GetNewClosure() `
    -AbortPollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 6) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($dispatch.Aborted) "an abort mid-dispatch is reported as Aborted"
Test-Assert ($dispatch.ForceKilledCount -eq 2) "the 2 running processes are force-killed after the abort timeout"
Test-Assert ($cleaned.Count -eq 5) ("-JobAbortCleanup runs for killed AND never-started jobs (got " + $cleaned.Count + ")")
Test-Assert ($dispatch -is [hashtable]) "the dispatcher returns exactly one result object, even on the force-kill path"
Test-Assert ($dispatch.GroupResults.Count -eq 1 -and $dispatch.GroupResults[0].Aborted) "the unfinished group is reported as aborted"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 15) ("the dispatcher returns promptly (" + [int]$sw.Elapsed.TotalSeconds + "s), not after 30s of ping")
Write-Host ""

# ==============================================================================
Write-Host "=== I: dispatchers inside workers, sharing one process budget ===" -ForegroundColor Cyan
Reset-Harness
# Two "engines", each its own runspace running its own dispatcher, both
# drawing on one shared SemaphoreSlim of 2.
$budget = [System.Threading.SemaphoreSlim]::new(2, 2)
$engine = {
    param([string]$Name, [System.Threading.SemaphoreSlim]$Budget, [string]$PingExe, $Peak)
    $feed = @{ Index = 0 }
    $done = @{ Count = 0 }
    $dispatch = Invoke-PkProcessDispatch -MaxConcurrent $Budget `
        -GroupProvider { if ($feed.Index -ge 2) { return $null }; $feed.Index++; return @{ Id = $feed.Index } }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $PingExe; Arguments = '-n 2 127.0.0.1' }, @{ FilePath = $PingExe; Arguments = '-n 2 127.0.0.1' }) }.GetNewClosure() `
        -AbortPollCallback { param($running) $inUse = 2 - $Budget.CurrentCount; if ($inUse -gt $Peak.Max) { $Peak.Max = $inUse } }.GetNewClosure() `
        -JobFinalize { param($job, $pending) $r = Complete-PkProcess -Job $job; if ($r.ExitCode -eq 0) { $done.Count++ } }.GetNewClosure()
    Write-PkMessage ("engine " + $Name + " finished " + $done.Count)
    return @{ Name = $Name; Done = $done.Count; Aborted = $dispatch.Aborted }
}
$peak = @{ Max = 0 }
$results = [System.Collections.Generic.List[hashtable]]::new()
$jobs = New-JobList -Jobs @(@{ Name = 'A'; Budget = $budget; PingExe = $pingExe; Peak = $peak }, @{ Name = 'B'; Budget = $budget; PingExe = $pingExe; Peak = $peak })
$out = Invoke-PkRunspaceJobs -WorkerScript $engine -JobParams $jobs -MaxParallel 2 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -CheckWorkerSafety
Test-Assert ($out.CrashedCount -eq 0) "dispatchers run inside worker runspaces without crashing"
$total = 0; foreach ($r in $results) { $total += $r.Done }
Test-Assert ($total -eq 8) ("both engines finish all their processes (8 total, got " + $total + ")")
Test-Assert ($peak.Max -le 2) ("the shared budget is never exceeded across both engines (peak " + $peak.Max + ")")
Test-Assert ($budget.CurrentCount -eq 2) "every budget slot is handed back"
Test-Assert (@($script:messages | Where-Object { $_.Message -like 'engine * finished 4' }).Count -eq 2) "messages written inside the engines reach the main thread"
$budget.Dispose()
Write-Host ""

# ==============================================================================
# Many threads registering/unregistering cancellation sources at once.
$churn = {
    param([int]$Id)
    for ($i = 0; $i -lt 300; $i++) {
        $c = [System.Threading.CancellationTokenSource]::new()
        Register-PkCancellationSource -Cts $c
        Unregister-PkCancellationSource -Cts $c
        $c.Dispose()
    }
    return $Id
}
$before = [PkState]::SourceCount
$churnOut = Invoke-PkRunspaceJobs -WorkerScript $churn -JobParams (New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })) -MaxParallel 6
Test-Assert ($churnOut.CrashedCount -eq 0 -and [PkState]::SourceCount -eq $before) "cancellation sources can be registered and unregistered from 6 workers at once"
Write-Host ""

# ==============================================================================
Write-Host "=== J: Invoke-PkRun bracket ===" -ForegroundColor Cyan
Reset-Harness
$inside = @{ RunActive = $false }
$value = Invoke-PkRun -ScriptBlock { $inside.RunActive = [PkConsoleCtrl]::RunActive; return 42 }.GetNewClosure()
Test-Assert ($inside.RunActive -eq $true) "the handler is armed while the run's scriptblock executes"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "and disarmed afterwards"
Test-Assert ($value -eq 42) "the scriptblock's output passes through"
Test-Assert ([PkConsoleCtrl]::DrainComplete.IsSet) "the drain is marked complete on the way out"
$threw = $false
try { Invoke-PkRun -ScriptBlock { throw "inner" } } catch { $threw = $true }
Test-Assert ($threw -and [PkConsoleCtrl]::RunActive -eq $false) "an exception still disarms the handler"
# Nested runs: the inner one must not disarm or reset the outer one.
$nested = @{ AfterInner = $false; AbortKept = $false; Inner = 0 }
Invoke-PkRun -ScriptBlock {
    Request-PkAbort
    $nested.Inner = Invoke-PkRun -ScriptBlock { return 7 }
    $nested.AfterInner = [PkConsoleCtrl]::RunActive
    $nested.AbortKept  = [PkConsoleCtrl]::AbortRequested
}.GetNewClosure()
Test-Assert ($nested.Inner -eq 7) "a nested Invoke-PkRun still runs its scriptblock and passes its output through"
Test-Assert ($nested.AfterInner -eq $true) "the outer run stays armed after a nested run ends"
Test-Assert ($nested.AbortKept -eq $true) "a nested run does not wipe the outer run's abort state"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "the outer run still disarms at its own end"
# A stale abort from a previous run must not leak into the next one.
Request-PkAbort
$null = Test-PkAbortSignal
$leaked = Invoke-PkRun -ScriptBlock { return (Test-PkAbortSignal) }
Test-Assert ($leaked -eq $false) "each run starts with a clean abort state"
Write-Host ""

# ==============================================================================
Write-Host "=== K: worker-safety check ===" -ForegroundColor Cyan
Reset-Harness
function Get-HarnessUnsafeState { return $script:someState }
function Get-HarnessUsesCmdlet  { return (Get-Date) }
function Get-HarnessCallsOther  { return (Get-HarnessDouble -Value 2) }
function Get-HarnessDelegate    { return [Func[int]]{ 1 } }
function Get-HarnessIgnored     { return $script:someState }  # pk:ignore

$f = Test-PkWorkerSafety -WorkerScript { param($Id) return (Get-HarnessDouble -Value $Id) } -SharedFunctionNames @('Get-HarnessDouble')
Test-Assert ($f.Count -eq 0) "clean worker code produces no findings"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) return (Get-HarnessDouble -Value $Id) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction') "a worker calling an unshared function is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessCallsOther } -SharedFunctionNames @('Get-HarnessCallsOther')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction' -and $f[0].Where -eq 'function Get-HarnessCallsOther') "a shared function calling an unshared one is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessUnsafeState } -SharedFunctionNames @('Get-HarnessUnsafeState')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "a shared function using `$script: is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $script:top = 1; $sb = { $script:nested = 2 } }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "in the worker body, only `$script: inside a nested scriptblock is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Start-Sleep -Milliseconds 5; @(1, 2) | Where-Object { $_ -gt 1 } | ForEach-Object { $_ }; Get-HarnessUsesCmdlet } -SharedFunctionNames @('Get-HarnessUsesCmdlet')
Test-Assert ($f.Count -eq 0) ("cmdlets, including ones that take a scriptblock, pass the check in the worker body and in shared functions (got " + $f.Count + " finding(s))")
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessDelegate } -SharedFunctionNames @('Get-HarnessDelegate')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock-to-delegate cast is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessIgnored } -SharedFunctionNames @('Get-HarnessIgnored')
Test-Assert ($f.Count -eq 0) "'# pk:ignore' on the line accepts a finding"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Write-PkMessage "x"; if (Test-PkCancelRequested) { return }; $null = Start-PkProcess -FilePath 'x' }
Test-Assert ($f.Count -eq 0) "the kit's own worker functions never need listing"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -CheckWorkerSafety } catch { $threw = ($_.ToString() -like '*Func*') }
Test-Assert $threw "-CheckWorkerSafety refuses to launch unsafe worker code, naming the problem"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like '*Func*') }
Test-Assert $threw "the worker-safety check runs without being asked"
$out = $null
try { $out = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -CheckWorkerSafety:$false } catch { Write-Host "  opt-out threw: $_" }
Test-Assert ($null -ne $out -and $out.CrashedCount -eq 0) "-CheckWorkerSafety:`$false turns the check off"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($Id) return @(1, 2, 3) | Where-Object { $_ -gt 1 } | Measure-Object -Sum | ForEach-Object { $_.Sum + $Id } } `
    -JobParams (New-JobList -Jobs @(@{ Id = 10 }, @{ Id = 20 })) -MaxParallel 2 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and (@($results | Sort-Object) -join ',') -eq '15,25') "workers can run cmdlets, including ones that take a scriptblock"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } `
    -JobParams (New-JobList -Jobs @(@{ Path = $cmdExe })) -MaxParallel 1 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq (Get-FileHash -LiteralPath $cmdExe -Algorithm SHA256).Hash) "a function from a module (Get-FileHash) needn't be shared, and autoloads in the worker"

# A scriptblock passed as a job value runs against the main thread's session
# state - refused at launch, with the pass-as-text workaround.
$mainThreadBlock = { param($x) $x * 2 }
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fn) } -JobParams (New-JobList -Jobs @(@{ Fn = 'ok' }, @{ Fn = $mainThreadBlock })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*job 1*'Fn'*Create*Nothing was started*") }
Test-Assert $threw "a scriptblock job value is refused before any worker starts, naming the job and key"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fns) } -JobParams (New-JobList -Jobs @(@{ Fns = @(1, $mainThreadBlock) })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*'Fns'*") }
Test-Assert $threw "a scriptblock inside an array job value is refused too"
$threw = $false
$providerState = @{ Given = 0 }
$provider = { if ($providerState.Given -ge 2) { return $null }; $providerState.Given++; if ($providerState.Given -eq 2) { return @{ Fn = $mainThreadBlock } }; return @{ Fn = 'ok' } }.GetNewClosure()
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fn) } -NextJobProvider $provider -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*-NextJobProvider*'Fn'*") }
Test-Assert $threw "a scriptblock job value from -NextJobProvider is refused"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($FnText, $Id) $fn = [scriptblock]::Create($FnText); return (& $fn $Id) } `
    -JobParams (New-JobList -Jobs @(@{ FnText = $mainThreadBlock.ToString(); Id = 4 })) -MaxParallel 1 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq 8) "the pass-as-text workaround runs"
Write-Host ""

# ==============================================================================
Write-Host "=== L: message handler ===" -ForegroundColor Cyan
Reset-Harness
Write-PkMessage "main-thread message" -Level Warn
Test-Assert ($script:messages.Count -eq 1 -and $script:messages[0].Level -eq 'Warn') "on the main thread, Write-PkMessage goes straight to the handler"
# Called from inside a closure, where a $script:-based handler would have vanished.
$closure = { Write-PkMessage "from a closure" }.GetNewClosure()
& $closure
Test-Assert ($script:messages.Count -eq 2) "the handler is still found when called from inside a .GetNewClosure()'d block"
Write-Host ""

# ==============================================================================
Write-Host "=== M: callbacks that output things ===" -ForegroundColor Cyan
Reset-Harness
# Every callback below emits stray output. None of it may reach a return value.
$poll = @{ Count = 0 }
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 50; $i++) { if (Test-PkCancelRequested) { return $Id }; [System.Threading.Thread]::Sleep(100) }; return $Id } `
    -ResultHandler { param($r) $true; 123 } `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 4) { Request-PkAbort }; "noise" }.GetNewClosure()
Test-Assert ($out -is [hashtable] -and $out.Aborted) "runspace jobs: noisy -ResultHandler/-PollCallback don't corrupt the result, even through an abort drain"

Reset-Harness
$crashOut = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -WorkerScript { param($Id) throw "x" } -JobCrashedHandler { param($e) "noise"; 5 }
Test-Assert ($crashOut -is [hashtable] -and $crashOut.CrashedCount -eq 1) "runspace jobs: a noisy -JobCrashedHandler doesn't corrupt the result"

Reset-Harness
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$noisy = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'n' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }, @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -JobAbortCleanup { param($job) "noise"; $true } `
    -GroupCompleteCallback { param($group) "noise"; 1 } `
    -AbortPollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { Request-PkAbort }; "noise" }.GetNewClosure()
Test-Assert ($noisy -is [hashtable] -and $noisy.ForceKilledCount -eq 1) "dispatch: noisy -JobAbortCleanup/-GroupCompleteCallback/-AbortPollCallback don't corrupt the result"

Reset-Harness
$noisyBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1 -OnComplete { param($c, $r) "noise"; $true }
Test-Assert ($noisyBatch -is [hashtable] -and $noisyBatch.Results.Count -eq 1) "batch: a noisy -OnComplete doesn't corrupt the result"

Set-PkMessageHandler -Handler { param($Message, $Level) "noise"; 42 }
$leaked = Write-PkMessage "hello"
Test-Assert ($null -eq $leaked) "a message handler's output doesn't leak out of Write-PkMessage"
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()
Write-Host ""

# ==============================================================================
Write-Host "=== N: careless job starters and retries ===" -ForegroundColor Cyan
Reset-Harness
function Invoke-HarnessOneGroupDispatch {
    # One group, $JobCount jobs, with the given starter/finalize.
    param([scriptblock]$JobStarter, [scriptblock]$JobFinalize, [int]$JobCount = 1, [hashtable]$Done)
    $feed = @{ Given = $false }
    $count = $JobCount
    return Invoke-PkProcessDispatch -MaxConcurrent 2 -AbortTimeoutSeconds 2 -JobStarter $JobStarter -JobFinalize $JobFinalize `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'one' } }.GetNewClosure() `
        -JobBuilder { param($g) return @(1..$count | ForEach-Object { @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }) }.GetNewClosure() `
        -GroupCompleteCallback { param($group) $Done.Groups++ }.GetNewClosure()
}

# Fills in the job it was given but forgets to return it.
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobCount 2 `
    -JobStarter { param($job) $s = Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments; $job.Proc = $s.Proc; $job.StdoutTask = $s.StdoutTask; $job.StderrTask = $s.StderrTask } `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Jobs -eq 2 -and $done.Groups -eq 1) "a starter that fills in the job but forgets to return it still works"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 10) "and the dispatcher doesn't hang on it"

# Returns the job, but with stray output in front of it.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$d = Invoke-HarnessOneGroupDispatch -Done $done `
    -JobStarter { param($job) "noise"; $s = Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments; $job.Proc = $s.Proc; $job.StdoutTask = $s.StdoutTask; $job.StderrTask = $s.StderrTask; return $job } `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $d.JobStarterFailedCount -eq 0) "a starter that leaks output before the job is still understood"

# Never starts anything at all.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter { param($job) return $job } -JobFinalize { param($job, $pending) $done.Jobs++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($d.JobStarterFailedCount -eq 1 -and $done.Groups -eq 1 -and $sw.Elapsed.TotalSeconds -lt 10) "a starter that never sets .Proc is reported as a failed start instead of spinning forever"
Test-Assert (@($script:messages | Where-Object { $_.Message -like "*did not set the job's .Proc*" }).Count -eq 1) "with a message saying what the starter got wrong"

# A retry job enqueued without its GroupKey.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0; Retried = $false }
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter $null -JobFinalize {
    param($job, $pending)
    $null = Complete-PkProcess -Job $job
    if (-not $done.Retried) {
        $done.Retried = $true
        $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })   # no GroupKey copied
        return @{ Requeued = $true }
    }
    $done.Jobs++
}.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $done.Groups -eq 1 -and -not $d.Aborted) "a retry job enqueued without its GroupKey is still credited to the right group"

# Complete-PkProcess on a job with no read tasks.
$bare = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 5'
$null = Wait-PkProcess -Process $bare.Proc -TimeoutMs 5000
$threw = $false
try { $bareResult = Complete-PkProcess -Job @{ Proc = $bare.Proc } } catch { $threw = $true }
Test-Assert (-not $threw -and $bareResult.ExitCode -eq 5 -and $null -eq $bareResult.Stdout) "Complete-PkProcess copes with a job that has no output-read tasks"
$bare.Proc.Dispose()
Write-Host ""

# ==============================================================================
Write-Host "=== O: aborts and the caller's own tokens ===" -ForegroundColor Cyan
Reset-Harness
# A caller-supplied source is cancelled by an abort, and left registered nowhere.
$mine = [System.Threading.CancellationTokenSource]::new()
$poll = @{ Count = 0 }
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -Cts $mine -JobParams (New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 50; $i++) { if (Test-PkCancelRequested) { return $Id }; [System.Threading.Thread]::Sleep(100) }; return $Id } `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 4) { Request-PkAbort } }.GetNewClosure()
Test-Assert ($out.Aborted -and $mine.IsCancellationRequested) "runspace jobs: an abort cancels a caller-supplied -Cts"
Test-Assert ($results.Count -eq 2) ("so the remaining jobs are not launched (ran " + $results.Count + " of 6)")
Test-Assert ([PkState]::SourceCount -eq 0) "and the caller's source is not left registered"
$mine.Dispose()

Reset-Harness
$mine = [System.Threading.CancellationTokenSource]::new()
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mine.Token `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'c' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(1..3 | ForEach-Object { @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' } }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -AbortPollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($d.Aborted -and $sw.Elapsed.TotalSeconds -lt 15) "dispatch: an abort stops a run that was given the caller's own -CancelToken"
Test-Assert (-not $mine.IsCancellationRequested) "without cancelling the caller's own token"
Test-Assert ([PkState]::SourceCount -eq 0) "and nothing is left registered"

# ...and the caller's token still works as a cancel.
Reset-Harness
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mine.Token `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'c2' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -AbortPollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { $mine.Cancel() } }.GetNewClosure()
Test-Assert ($d.Aborted -and $d.ForceKilledCount -eq 1) "dispatch: cancelling the caller's own token still stops the run"
$mine.Dispose()

# An abort stays in force until it is reset.
Reset-Harness
Request-PkAbort
$null = Test-PkAbortSignal
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) if (Test-PkCancelRequested) { return }; return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.Aborted -eq $true -and $results.Count -eq 0) "a run started while an earlier abort is still in force reports Aborted instead of silently doing nothing"
$batchAfter = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1
Test-Assert ($batchAfter.Aborted -eq $true) "the same goes for a process batch"
Reset-PkAbortState
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) if (Test-PkCancelRequested) { return }; return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert (-not $out.Aborted -and $results.Count -eq 4) "after Reset-PkAbortState the next run is normal again"

# Your own long step inside Invoke-PkRun has to poll.
Reset-Harness
$own = @{ Steps = 0 }
Invoke-PkRun -ScriptBlock {
    for ($i = 0; $i -lt 1000; $i++) {
        if ($i -eq 3) { Request-PkAbort }
        if (Test-PkAbortSignal) { break }
        $own.Steps++
    }
}.GetNewClosure()
Test-Assert ($own.Steps -eq 3) "your own loop inside Invoke-PkRun can stop on an abort by polling Test-PkAbortSignal"
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Ctrl+C detected*' }).Count -eq 1) "and the abort is announced once"

# QuickEdit is put back the way it was found.
Reset-Harness
$quickEditBefore = [PkConsoleQuickEdit]::GetEnabled()
Invoke-PkRun -ScriptBlock { }
Test-Assert ($quickEditBefore -in @(-1, 0, 1) -and [PkConsoleQuickEdit]::GetEnabled() -eq $quickEditBefore) ("QuickEdit is left as it was found after a run (state " + $quickEditBefore + ")")
if ($quickEditBefore -eq 1) {
    $null = [PkConsoleQuickEdit]::SetEnabled($false)
    Invoke-PkRun -ScriptBlock { }
    Test-Assert ([PkConsoleQuickEdit]::GetEnabled() -eq 0) "a console that had QuickEdit off still has it off after a run"
    $null = [PkConsoleQuickEdit]::SetEnabled($true)
}
Write-Host ""

# ==============================================================================
Write-Host "=== P: edge cases - delegate detection, self-setup, careless callbacks ===" -ForegroundColor Cyan
Reset-Harness

# The safety check sees scriptblocks handed straight to .NET.
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $d = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new(); $null = $d.GetOrAdd('a', { 1 }) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock passed straight to a .NET method is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $lazy = [System.Lazy[object]]::new({ 1 }) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock passed to a .NET constructor is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $x = @(1, 2).ForEach({ $_ }); $y = @(1, 2).Where({ $_ }); $z = { 1 }.GetNewClosure() }
Test-Assert ($f.Count -eq 0) "PowerShell's own .ForEach()/.Where()/.GetNewClosure() are not flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $factory = { 1 }; $lazy = [System.Lazy[object]]::new($factory) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast' -and $f[0].Text -like '*$factory*') "a variable holding a scriptblock, passed to a .NET constructor, is flagged by name"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $add = { param($k, $old) $old + 1 }.GetNewClosure(); $d = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new(); $null = $d.AddOrUpdate('a', 1, $add) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a variable holding a .GetNewClosure() block, passed to a .NET method, is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $sb = { $_ * 2 }; $n = 'x'; $x = @(1, 2).ForEach($sb); $null = $n.Contains($n) }
Test-Assert ($f.Count -eq 0) "a scriptblock variable given to .ForEach(), and other variables given to .NET methods, are not flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $list = [System.Collections.Generic.List[scriptblock]]::new(); $list.Add({ 1 })  # pk:ignore
}
Test-Assert ($f.Count -eq 0) "'# pk:ignore' accepts a method that really does take a scriptblock"

# With no Initialize-ParallelKit at all, starting a process sets up the
# thread pool and the kill-on-close job object. Needs a fresh process.
$probeScript = Join-Path $env:TEMP ("pk-probe-" + [guid]::NewGuid().ToString("N") + ".ps1")
$kitPath = Join-Path $PSScriptRoot "ParallelKit.ps1"
[System.IO.File]::WriteAllText($probeScript, @"
. '$kitPath'
`$before = [PkChildProcessJob]::IsInitialized
`$j = Start-PkProcess -FilePath '$cmdExe' -Arguments '/c exit 0'
`$null = Wait-PkProcess -Process `$j.Proc -TimeoutMs 5000
`$w = 0; `$io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]`$w, [ref]`$io)
Write-Output ("before=" + `$before + " after=" + [PkChildProcessJob]::IsInitialized + " threads=" + `$w)
"@)
$probe = Invoke-PkProcessWithTimeout -FilePath (Join-Path $PSHOME "powershell.exe") -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $probeScript + '"') -TimeoutMs 60000
[System.IO.File]::Delete($probeScript)
Test-Assert ($probe.Stdout -match 'before=False after=True') ("starting a process sets up child cleanup by itself (" + ([string]$probe.Stdout).Trim() + ")")
$probeThreads = 0
if ($probe.Stdout -match 'threads=(\d+)') { $probeThreads = [int]$Matches[1] }
Test-Assert ($probeThreads -ge 128) ("and raises the thread pool by itself (minimum " + $probeThreads + ")")

# The dispatcher sizes the pool for its own concurrency.
$feed = @{ Given = $false }
$null = Invoke-PkProcessDispatch -MaxConcurrent 100 -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) }
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 232) ("the dispatcher raises the thread pool to fit -MaxConcurrent (minimum " + $w + " for 100 processes)")

# A one-line starter keeps the caller's job fields.
Reset-Harness
$feed = @{ Given = $false }
$seenTags = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 's' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'first' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'second' }) }.GetNewClosure() `
    -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
    -JobFinalize { param($job, $pending) $r = Complete-PkProcess -Job $job; $seenTags.Add($job.Tag) }.GetNewClosure()
Test-Assert ($seenTags.Count -eq 2 -and ($seenTags -contains 'first') -and ($seenTags -contains 'second')) "a starter that is just 'Start-PkProcess ...' keeps the job's own fields for JobFinalize"
Test-Assert ($d.JobStarterFailedCount -eq 0 -and $d.GroupResults.Count -eq 1) "and the jobs run and complete normally"

# A message handler that throws.
Reset-Harness
Set-PkMessageHandler -Handler { param($Message, $Level) throw "log file locked" }
$results = [System.Collections.Generic.List[object]]::new()
$threw = $false
try {
    $out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) `
        -WorkerScript { param([int]$Id) Write-PkMessage ("from " + $Id); if ($Id -eq 2) { throw "boom" }; return $Id } `
        -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
} catch { $threw = $true }
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()
Test-Assert (-not $threw -and $out.CrashedCount -eq 1 -and $results.Count -eq 2) "a message handler that throws doesn't take the run down"

# Stray output from a builder and from a provider.
Reset-Harness
$feed = @{ Given = $false }
$done = @{ Jobs = 0 }
$seenGroups = [System.Collections.Generic.HashSet[string]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'b' } }.GetNewClosure() `
    -JobBuilder { param($g) $seenGroups.Add($g.Name); "noise"; return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $d.GroupResults.Count -eq 1) "a job builder that lets stray output escape still gets its job run"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Warn' -and $_.Message -like '*-JobBuilder returned 2 value(s)*' }).Count -eq 1) "and the ignored values are reported"

Reset-Harness
$feed = @{ Next = 1 }
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -WorkerScript { param([int]$Id) return $Id } `
    -NextJobProvider { if ($feed.Next -gt 3) { return $null }; "noise"; $j = @{ Id = $feed.Next }; $feed.Next++; return $j }.GetNewClosure() `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 3 -and $out.CrashedCount -eq 0) "a job provider that lets stray output escape still feeds its jobs"

# Working directory on the single-process helper.
$wdResult = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory $env:SystemRoot
Test-Assert ($wdResult.Stdout.Trim() -ieq $env:SystemRoot) "Invoke-PkProcessWithTimeout honors -WorkingDirectory"

# A bad key in a fixed job list is caught before anything runs.
Reset-Harness
$ran = @{ Count = 0 }
$gate = [object]::new()
$threw = $false
try {
    $null = Invoke-PkRunspaceJobs -MaxParallel 1 `
        -JobParams (New-JobList -Jobs @(@{ Id = 1; Ran = $ran; Gate = $gate }, @{ Id = 2; Ran = $ran; Gate = $gate }, @{ Id = 3; Ran = $ran; Gate = $gate; Typo = 1 })) `
        -WorkerScript { param([int]$Id, $Ran, $Gate) [System.Threading.Monitor]::Enter($Gate); try { $Ran.Count++ } finally { [System.Threading.Monitor]::Exit($Gate) }; return $Id }
} catch { $threw = ($_.ToString() -like "*job 2 supplies 'Typo'*Nothing was started*") }
[System.Threading.Thread]::Sleep(300)
Test-Assert ($threw -and $ran.Count -eq 0) ("a bad key in -JobParams is reported before any worker starts (workers run: " + $ran.Count + ")")
Write-Host ""

# ==============================================================================
Write-Host "=== Q: edge cases - follow-up jobs, re-queued jobs, -JobParams shapes ===" -ForegroundColor Cyan

# The dispatcher counts what JobFinalize queued, not what it returns: a
# return value claiming a requeue, with nothing queued, must not hang the group.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter $null -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++; return @{ Requeued = $true } }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Groups -eq 1 -and $sw.Elapsed.TotalSeconds -lt 10) "a JobFinalize return value is ignored - claiming a requeue with nothing queued doesn't hang the dispatcher"

# Two follow-up jobs, no flag: the group completes only after ALL of them.
Reset-Harness
$feed = @{ Given = $false }
$order = [System.Collections.Generic.List[string]]::new()
$state = @{ Split = $false }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'split' } }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $order.Add('job')
        if (-not $state.Split) {
            $state.Split = $true
            $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })
            $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })
        }
    }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $order.Add('group') }.GetNewClosure()
Test-Assert (($order -join ',') -eq 'job,job,job,group') ("a group whose job queues two follow-ups completes only after both finish (order: " + ($order -join ',') + ")")

# The same job object put back on the queue, with a one-line starter.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Retried = $false; Finalized = 0 }
$threw = $false
try {
    $d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 're' } }.GetNewClosure() `
        -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'keep' } }.GetNewClosure() `
        -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
        -JobFinalize {
            param($job, $pending)
            $null = Complete-PkProcess -Job $job
            $state.Finalized++
            if (-not $state.Retried) { $state.Retried = $true; $pending.Enqueue($job) }
        }.GetNewClosure()
} catch { $threw = $true }
Test-Assert (-not $threw -and $state.Finalized -eq 2 -and $d.GroupResults.Count -eq 1) "putting the SAME job object back on the queue runs it again cleanly"

# -JobParams: one bare hashtable, a plain array, and a bad entry.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$oneJob = foreach ($n in @(7)) { @{ Id = $n } }
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams $oneJob -WorkerScript { param([int]$Id) return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 1 -and $results[0] -eq 7) "-JobParams accepts a job list that collapsed to a single hashtable"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param([int]$Id) return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 2) "-JobParams accepts a plain array of hashtables"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }, 'oops') -WorkerScript { param($Id) } } catch { $threw = ($_.ToString() -like '*entry 1 is not a hashtable*') }
Test-Assert $threw "-JobParams with a non-hashtable entry fails with a message naming the entry"

# A shared budget sizes the thread pool too.
$bigBudget = [System.Threading.SemaphoreSlim]::new(150, 150)
$null = Invoke-PkProcessDispatch -MaxConcurrent $bigBudget -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) }
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 332) ("a shared budget of 150 raises the thread pool to fit (minimum " + $w + ")")
$bigBudget.Dispose()
Write-Host ""

# ==============================================================================
Write-Host "=== R: edge cases - group identity, .Group, large batches ===" -ForegroundColor Cyan

# Two groups that compare equal keep separate job counts.
Reset-Harness
$feed = @{ Index = 0 }
$order = [System.Collections.Generic.List[string]]::new()
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge 2) { return $null }; $feed.Index++; return 'Group 1' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $order.Add('job'); $groupsSeen.Add($job.Group) }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $order.Add('group') }.GetNewClosure()
Test-Assert (($order -join ',') -eq 'job,job,group,job,job,group') ("two groups with the same name each complete after their own two jobs (order: " + ($order -join ',') + ")")
Test-Assert ($d.GroupResults.Count -eq 2) "and both are reported"
Test-Assert ($groupsSeen.Count -eq 4 -and @($groupsSeen | Where-Object { $_ -ne 'Group 1' }).Count -eq 0) "each job carries its group value as .Group"

# A follow-up job inherits .Group as well as its place in the group.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Split = $false }
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'only' }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $groupsSeen.Add($job.Group)
        if (-not $state.Split) { $state.Split = $true; $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }
    }.GetNewClosure()
Test-Assert ($groupsSeen.Count -eq 2 -and $groupsSeen[1] -eq 'only') "a follow-up job gets its group's .Group too"

# A re-run job gets a fresh stopwatch.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Retried = $false }
$watches = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'sw' } }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $watches.Add($job.Stopwatch)
        if (-not $state.Retried) { $state.Retried = $true; $pending.Enqueue($job) }
    }.GetNewClosure()
Test-Assert ($watches.Count -eq 2 -and $null -ne $watches[1] -and -not [object]::ReferenceEquals($watches[0], $watches[1])) "a job that goes round again gets a fresh stopwatch"

# A large batch isn't slowed by per-job queue walks. No processes: the
# starter/poll are stubs, so this times the dispatcher's own bookkeeping.
Reset-Harness
$bigCount = 20000
$feed = @{ Given = $false }
$done = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1000 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'big' } }.GetNewClosure() `
    -JobBuilder { param($g) $jobs = [System.Collections.Generic.List[hashtable]]::new(); for ($i = 0; $i -lt $bigCount; $i++) { $jobs.Add(@{ Id = $i }) }; return $jobs }.GetNewClosure() `
    -JobStarter { param($job) return $job } -JobPollCompleted { param($job) return $true } `
    -JobFinalize { param($job, $pending) $done.Count++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Count -eq $bigCount) "a 20,000-job group runs to completion"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 15) ("and the dispatcher's own bookkeeping stays quick (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s for 20,000 jobs)")
Write-Host ""

# ==============================================================================
Write-Host "=== S: edge cases - abort timing, strict mode, stale types, sleep, -IgnoreAbort ===" -ForegroundColor Cyan

# Invoke-PkProcessWithTimeout stops promptly on an abort. The abort is
# raised from another thread while the main thread is inside the wait.
Reset-Harness
$abortTimer = [PowerShell]::Create()
$null = $abortTimer.AddScript({ [System.Threading.Thread]::Sleep(700); [PkConsoleCtrl]::AbortRequested = $true })
$abortTimerHandle = $abortTimer.BeginInvoke()
$threw = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 25000 } catch { $threw = ($_.ToString() -like '*being aborted*') }
$sw.Stop()
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 6) ("Invoke-PkProcessWithTimeout stops its program when the run is aborted (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, time limit was 25s)")
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Ctrl+C detected*' }).Count -eq 1) "and the abort is announced"
$null = $abortTimer.EndInvoke($abortTimerHandle); $abortTimer.Dispose()

# The same from inside a worker, where the run's cancel is what it sees.
Reset-Harness
$poll = @{ Count = 0 }
$workerErrors = [System.Collections.Generic.List[object]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @{ PingExe = $pingExe } -DrainTimeoutSeconds 20 `
    -WorkerScript { param($PingExe) try { $null = Invoke-PkProcessWithTimeout -FilePath $PingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 25000; return 'finished' } catch { return [string]$_ } } `
    -ResultHandler { param($r) $workerErrors.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 6) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($workerErrors.Count -eq 1 -and $workerErrors[0] -like '*being aborted*' -and $sw.Elapsed.TotalSeconds -lt 8 -and $out.ForceStoppedCount -eq 0) ("inside a worker it stops on the run's abort too (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)")

Reset-Harness
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$threw = $false
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 900 } catch { $threw = ($_.ToString() -like '*did not exit within 900ms*') }
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 5) "the plain time limit still works and reports itself as a timeout"
$quick = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c exit 9'
Test-Assert ($quick.ExitCode -eq 9) "and a program that finishes in time is returned normally"

# Reset-PkAbortState part-way through a run leaves the run armed.
Reset-Harness
$mid = @{ ArmedAfterReset = $false; AbortCleared = $false; SecondPhase = 0 }
Invoke-PkRun -ScriptBlock {
    Request-PkAbort
    $null = Test-PkAbortSignal
    Reset-PkAbortState
    $mid.ArmedAfterReset = [PkConsoleCtrl]::RunActive
    $mid.AbortCleared    = -not (Test-PkAbortSignal)
    $second = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1
    if (-not $second.Aborted) { $mid.SecondPhase = $second.Results.Count }
}.GetNewClosure()
Test-Assert ($mid.ArmedAfterReset -eq $true) "Reset-PkAbortState inside a run leaves Ctrl+C handling armed"
Test-Assert ($mid.AbortCleared -and $mid.SecondPhase -eq 1) "and the next phase of that run then works normally"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "the run still disarms at its own end"

# A worker that turns strict mode on can still use the kit's functions.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @{ CmdExe = $cmdExe } `
    -WorkerScript {
        param($CmdExe)
        Set-StrictMode -Version Latest   # pk:ignore
        $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $CmdExe; Arguments = '/c exit 0' }, @{ FilePath = 'C:\no\such\program.exe' }) -MaxConcurrent 2
        $single = Invoke-PkProcessWithTimeout -FilePath $CmdExe -Arguments '/c exit 6'
        Write-PkMessage "strict worker done"
        return ("results=" + $batch.Results.Count + " exit=" + $single.ExitCode)
    } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq 'results=2 exit=6') ("the kit's process functions work inside a worker that runs under strict mode (" + ($results -join '') + ")")

# Loading the kit into a session that holds an older copy's compiled types
# says so clearly. Needs a fresh process with stand-in "old" types.
$staleScript = Join-Path $env:TEMP ("pk-stale-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($staleScript, @"
Add-Type -TypeDefinition 'public static class PkConsoleCtrl { } public static class PkState { }'
try { . '$kitPath'; Write-Output 'LOADED' } catch { Write-Output ('REFUSED: ' + `$_) }
"@)
$stale = Invoke-PkProcessWithTimeout -FilePath (Join-Path $PSHOME "powershell.exe") -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $staleScript + '"') -TimeoutMs 60000
[System.IO.File]::Delete($staleScript)
Test-Assert ($stale.Stdout -like '*REFUSED:*older version of the kit*start a new one*') "loading the kit over an older copy's types is refused with a clear message"

# Invoke-PkRun keeps the PC from idle-sleeping only while it runs. Checked
# on this thread itself: SetThreadExecutionState returns the thread's
# previous state, so re-setting the same value reads it back. (The
# system-wide flag can't tell us anything - any other program keeping the
# PC awake already holds it.)
if (-not ([System.Management.Automation.PSTypeName]'PkThreadStateProbe').Type) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class PkThreadStateProbe { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }'
}
$esContinuous = [uint32]2147483648
$esKeepAwake  = [uint32]2147483649
Reset-Harness
$awakeDuring = Invoke-PkRun -ScriptBlock { return [PkThreadStateProbe]::SetThreadExecutionState($esKeepAwake) }.GetNewClosure()
$awakeAfter  = [PkThreadStateProbe]::SetThreadExecutionState($esContinuous)
Test-Assert ($awakeDuring -eq $esKeepAwake -and $awakeAfter -eq $esContinuous) ("Invoke-PkRun blocks idle sleep during the run and lifts it afterwards (during 0x" + ([uint32]$awakeDuring).ToString("X8") + ", after 0x" + ([uint32]$awakeAfter).ToString("X8") + ")")
$awakeOptOut = Invoke-PkRun -KeepAwake $false -ScriptBlock { return [PkThreadStateProbe]::SetThreadExecutionState($esContinuous) }.GetNewClosure()
Test-Assert ($awakeOptOut -eq $esContinuous) "-KeepAwake `$false leaves sleep alone"

# Cleanup programs can still be run while an abort is in force.
Reset-Harness
Request-PkAbort
$null = Test-PkAbortSignal
$threw = $false
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 3 127.0.0.1' } catch { $threw = ($_.ToString() -like '*being aborted*') }
Test-Assert $threw "while an abort is in force, the helper stops a program by default"
$cleanup = $null
try { $cleanup = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 3 127.0.0.1' -IgnoreAbort } catch { }
Test-Assert ($null -ne $cleanup -and $cleanup.ExitCode -eq 0) "-IgnoreAbort lets a cleanup program run to the end during an abort"

# A job's own Group field is left alone.
Reset-Harness
$feed = @{ Given = $false }
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'the-group' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0'; Group = 'mine' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $groupsSeen.Add($job.Group) }.GetNewClosure()
Test-Assert ($groupsSeen.Count -eq 2 -and ($groupsSeen -contains 'mine') -and ($groupsSeen -contains 'the-group')) "a job's own Group field is kept; a job without one gets the group"

# The safety check looks inside functions defined in the worker script.
$f = Test-PkWorkerSafety -WorkerScript { param($Id) function Get-Inner { return $script:cache }; $script:top = 1; return (Get-Inner) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "`$script: inside a function defined in the worker script is flagged (the worker's own top level still isn't)"
Write-Host ""

# ==============================================================================
Write-Host "=== T: edge cases - tokens in workers, batch result fields, aborted groups ===" -ForegroundColor Cyan
Reset-Harness
# A dispatcher inside a worker, given a token of the worker's own making,
# must still stop on an abort - not run its processes to the end.
$ownTokenEngine = {
    param([string]$PingExe)
    $mineInWorker = [System.Threading.CancellationTokenSource]::new()
    $feed = @{ Given = $false }
    $d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mineInWorker.Token `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $PingExe; Arguments = '-n 30 127.0.0.1' }, @{ FilePath = $PingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
        -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job }
    return @{ Aborted = $d.Aborted; OwnCancelled = $mineInWorker.IsCancellationRequested }
}
$results = [System.Collections.Generic.List[hashtable]]::new()
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript $ownTokenEngine -JobParams @{ PingExe = $pingExe } -MaxParallel 1 -DrainTimeoutSeconds 20 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 15) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.ForceStoppedCount -eq 0 -and $results.Count -eq 1 -and $results[0].Aborted) ("a dispatcher in a worker with its own -CancelToken stops on an abort (force-stopped " + $out.ForceStoppedCount + ", " + [int]$sw.Elapsed.TotalSeconds + "s)")
Test-Assert ($results.Count -eq 1 -and -not $results[0].OwnCancelled) "without cancelling the worker's own token"
Test-Assert ([PkState]::SourceCount -eq 0) "and nothing is left registered"

# Every batch result has every documented field, so a strict-mode caller
# can read any of them without a "property cannot be found" error.
Reset-Harness
$fields = @('Command', 'ExitCode', 'Stdout', 'Stderr', 'StreamTimedOut', 'StreamError', 'StartError', 'Aborted')
$batch = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(
    @{ FilePath = $cmdExe; Arguments = '/c exit 0' },
    @{ FilePath = 'C:\definitely\not\here.exe' })
$missing = foreach ($r in $batch.Results) { foreach ($k in $fields) { if (-not $r.ContainsKey($k)) { $k } } }
Test-Assert ($batch.Results.Count -eq 2 -and @($missing).Count -eq 0) ("batch results for a finished and an unstartable command carry every field (missing: " + (@($missing) -join ', ') + ")")

# An abort already in force: nothing starts, every command comes back Aborted.
Reset-Harness
Request-PkAbort
$batch = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' })
$missing = foreach ($r in $batch.Results) { foreach ($k in $fields) { if (-not $r.ContainsKey($k)) { $k } } }
Test-Assert ($batch.Aborted -and $batch.Results.Count -eq 2 -and @($batch.Results | Where-Object { $_.Aborted }).Count -eq 2) "batch: commands an abort kept from starting come back marked Aborted"
Test-Assert (@($missing).Count -eq 0) ("and their results carry every field too (missing: " + (@($missing) -join ', ') + ")")
Reset-PkAbortState

# An aborted group still gets -GroupCompleteCallback (the README warns about
# this - a caller zipping a folder there must check for the abort first).
Reset-Harness
Request-PkAbort
$called = @{ Count = 0; SawAbort = $false }
$feed = @{ Given = $false }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -GroupCompleteCallback { param($g) $called.Count++; $called.SawAbort = [bool](Test-PkCancelRequested) }.GetNewClosure()
Test-Assert ($d.Aborted -and $called.Count -eq 1 -and $called.SawAbort) "an aborted group still gets its -GroupCompleteCallback, and Test-PkCancelRequested is true inside it"
Reset-PkAbortState
Write-Host ""

Set-PkMessageHandler -Handler $null
Reset-PkAbortState

Write-Host "==============================================="
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions)") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed") -ForegroundColor Red
}
Write-Host "==============================================="

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
