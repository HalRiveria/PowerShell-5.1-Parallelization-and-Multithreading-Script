# ParallelKit

[![Tests](https://github.com/HalRiveria/PowerShell-5.1-Parallelization-and-Multithreading-Script/actions/workflows/tests.yml/badge.svg)](https://github.com/HalRiveria/PowerShell-5.1-Parallelization-and-Multithreading-Script/actions/workflows/tests.yml)

Run thousands of command-line programs, or blocks of PowerShell code, in parallel from Windows PowerShell 5.1, and stop cleanly when you press Ctrl+C. One file, nothing to install.

- **Process dispatch** - run many external programs, a set number at a time, with their output captured.
- **Runspace jobs** - run a PowerShell worker script many times in parallel.
- **Graceful abort** - Ctrl+C or closing the window lets in-flight work finish and stops cleanly, instead of killing everything mid-write.
- **No orphans** - programs the script started die with it, even if it's force-closed.

It was pulled out of [Manga Conversion Script](https://github.com/HalRiveria/Manga-Conversion-Script), but has no dependencies on that project.

Built with Claude.

**Contents:** [Who it's for](#who-its-for) · [Setup](#setup) · [Run a list of programs](#run-a-list-of-programs) · [Run PowerShell code in parallel](#run-powershell-code-in-parallel) · [The three rules for worker code](#the-three-rules-for-worker-code) · [Process dispatch with groups](#process-dispatch-with-groups) · [Single processes](#single-processes) · [Messages](#messages) · [Abort](#abort) · [Choosing limits](#choosing-limits) · [Limits](#limits) · [Testing](#testing)

## Who it's for

Scripts that have to run on Windows PowerShell 5.1, the version built into every Windows 10, Windows 11 and Windows Server install. Usually that's because PowerShell 7 isn't installed or isn't allowed on the machines involved, or because the script has to run anywhere without asking anyone to install anything.

The typical job is batch work over lots of files with a command-line tool: converting images, audio or video, compressing archives, running a check or build step per file. That's what the process side is built for, and it's where most of the kit's care has gone.

If PowerShell 7 is an option, `ForEach-Object -Parallel` covers simple parallel loops. On 5.1, the ThreadJob module is simpler for running plain scriptblocks in parallel. Reach for ParallelKit when you also need any of these:

- Ctrl+C that lets running work finish instead of cutting it off mid-file.
- Child processes that are cleaned up even if the script is killed outright.
- A cap on how many external programs run at once, with their output captured without risk of a full-pipe deadlock.
- Work that comes in groups (a folder at a time, say), with retries or follow-up steps per file and something to do when each group is finished.

Which function you want:

| You have | Use |
|---|---|
| A flat list of external programs to run | `Invoke-PkProcessBatch` |
| Programs that come in groups, with something to do when each group is done | `Invoke-PkProcessDispatch` |
| PowerShell code to run in parallel | `Invoke-PkRunspaceJobs` |
| One program to run with a time limit | `Invoke-PkProcessWithTimeout` |

Wrap any of them in `Invoke-PkRun { ... }` to get graceful Ctrl+C.

## Setup

Requires Windows and Windows PowerShell 5.1. Copy `ParallelKit.ps1` into your project and dot-source it:

```powershell
. "$PSScriptRoot\ParallelKit.ps1"
$null = Initialize-ParallelKit -MaxConcurrentProcesses 8
```

If you downloaded the file, Windows marks it as coming from the internet and your execution policy may refuse to load it. Run `Unblock-File .\ParallelKit.ps1` once to clear that.

It works whether or not your script uses `Set-StrictMode`.

Dot-source it; don't `Import-Module` it. As a module it couldn't see the functions you list in `-SharedFunctionNames`.

`Initialize-ParallelKit` is optional. It registers the Ctrl+C handler, sets up child-process cleanup and sizes the thread pool up front; the engines set up what they need on first use either way. It returns `@{ AbortHandler; ChildProcessJob; ThreadPool }`, each `$true` if that part worked (a part that fails also prints a warning).

Each public function has a comment block at the top of its definition in `ParallelKit.ps1` listing its parameters and what it returns. `Get-Help` doesn't show these; read the file.

## Run a list of programs

```powershell
# Any command-line tool works. cjxl is a JPEG XL image encoder.
$commands = foreach ($f in Get-ChildItem *.png) {
    @{ FilePath = "cjxl.exe"; Arguments = "`"$($f.FullName)`" `"$($f.FullName).jxl`""; Source = $f }
}
$batch = Invoke-PkRun {
    Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 6 -OnComplete {
        param($command, $result)
        if ($result.ExitCode -ne 0) { Write-PkMessage "FAILED: $($command.Source.Name)" -Level Error }
    }
}
```

Each command is a hashtable with `FilePath`, `Arguments` and optionally `WorkingDirectory`, plus any keys of your own. `Arguments` is passed to the program as one string, exactly as written, so put quotes around paths that may contain spaces (as above). Programs run hidden, with their output captured.

`Invoke-PkProcessBatch` returns `@{ Results; Aborted; ForceKilledCount }`. Each result is `@{ Command; ExitCode; Stdout; Stderr; StreamTimedOut; StreamError; StartError; Aborted }`, with every field always present:

- `Command` is your original command hashtable, so extra keys like `Source` above come back with it.
- `ExitCode` is whatever the program returned. The kit doesn't treat a non-zero code as a failure; that's for you to decide.
- `StartError` is set when the program couldn't be started (not found, say).
- `Aborted` is `$true` for a command an abort killed or kept from starting.
- `StreamTimedOut` / `StreamError` mean the output may be incomplete. The output read gives up 15 seconds after the program exits, which only happens when a program it started is still holding the output open.

`Results` is in the order commands finished, not the order you gave them. Use `Command` to match them up.

`-OnComplete` runs as each command finishes, but only for commands that actually ran. Check `Results` for the ones that couldn't start or were aborted.

`Invoke-PkRun { ... }` is what makes Ctrl+C graceful. Whatever the block outputs is passed through, so `$batch` above gets the batch result. It also stops the PC idle-sleeping until the run ends (`-KeepAwake $false` to opt out); the display can still turn off. Without `Invoke-PkRun` the engines still work, but Ctrl+C kills the script the normal way. See "Abort" below for what it means for your own code inside the braces.

## Run PowerShell code in parallel

```powershell
# Worker code may only use .NET calls, not cmdlets - see "The three rules" below.
function Get-FileSha {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

$jobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($f in Get-ChildItem -File) { $jobs.Add(@{ Path = $f.FullName }) }
$shaByPath = @{}

$out = Invoke-PkRun {
    Invoke-PkRunspaceJobs -MaxParallel 4 -JobParams $jobs -SharedFunctionNames @('Get-FileSha') -CheckWorkerSafety `
        -WorkerScript {
            param([string]$Path)
            if (Test-PkCancelRequested) { return }
            Write-PkMessage "hashing $Path"
            return @{ Path = $Path; Sha = (Get-FileSha -Path $Path) }
        } `
        -ResultHandler { param($r) $shaByPath[$r.Path] = $r.Sha }.GetNewClosure()
}
```

Each worker runs in its own runspace: a separate PowerShell session inside the same process, with its own variables and functions. That separation is what makes running them at the same time safe, and also why a worker can't see your script's variables or functions unless you hand them over.

- Each job hashtable's keys become the worker's parameters. The worker's `param()` block must declare every key. A key it doesn't declare is an error; with a fixed `-JobParams` list it's caught before any worker starts.
- If the worker declares a `$CancelToken` parameter, it gets the run's cancellation token.
- `-JobParams` takes a list or array of job hashtables. A single hashtable works too, so a list that happens to hold one job is fine.
- A worker runspace starts empty. Name every one of your functions it calls in `-SharedFunctionNames`. The kit's own worker functions are always there.
- Whatever the worker returns is handed to `-ResultHandler` on the main thread, once per object returned.
- `-NextJobProvider { ... }` can replace `-JobParams` to produce jobs lazily: it's called on the main thread for the next job hashtable, and returns `$null` when there are no more.
- `-PollCallback { ... }` runs on the main thread on every loop pass, for progress display and the like.
- `-JobCrashedHandler { param($err) ... }` is told when a worker throws. That job's result handler isn't called.
- If one of your main-thread callbacks throws, the run stops: workers still going are told to stop and the exception comes out of the call.
- Returns `@{ ForceStoppedCount; CrashedCount; Aborted }`.

## The three rules for worker code

Worker code is the worker script, every function in `-SharedFunctionNames`, and anything they call. Breaking these rules doesn't fail loudly. It hangs, or quietly reads nothing.

1. **No `$script:` variables.** In a worker they can silently read as empty. Pass state in as job parameters. (`$script:` at the very top level of the worker script is fine; inside a function or a nested `{ }` block it isn't.)
2. **No cmdlets.** Two fresh runspaces calling the same cmdlet for the first time at the same moment can deadlock in PowerShell 5.1. Use .NET calls: `[System.IO.File]::Exists($p)` instead of `Test-Path`, `[System.Threading.Thread]::Sleep(100)` instead of `Start-Sleep`, a `foreach` loop instead of `ForEach-Object`, `$null = ...` instead of `| Out-Null`, `[DateTime]::Now` instead of `Get-Date`, `Write-PkMessage` instead of `Write-Host`.
3. **No scriptblocks handed to .NET as delegates** (`[Func[...]]{ }`, `[Action]{ }`, `System.Lazy`, `ConcurrentDictionary.GetOrAdd($k, { })`). Nested, they deadlock. Use plain loops and `[System.Threading.Monitor]`.

Only worker code is affected. Callbacks that run on the main thread (`-ResultHandler`, `-PollCallback`, `-NextJobProvider`, `-OnComplete`, the message handler) are not worker code and can use anything, cmdlets included.

`Test-PkWorkerSafety -WorkerScript $w -SharedFunctionNames $names` checks all three, plus missing shared functions, and returns a list of findings. For rule 3 it flags both written casts and scriptblocks passed straight into a .NET call. Call it from your tests, or pass `-CheckWorkerSafety` to `Invoke-PkRunspaceJobs` to refuse to launch unsafe code. `# pk:ignore` on a line accepts a finding. It can't see callbacks you pass to a worker as job parameters, or commands run through a variable (`& $cmd`).

### Why these rules exist

"No cmdlets" in PowerShell code sounds extreme, so here's where each rule comes from. All three were found chasing real, intermittent hangs, and none of them is documented by Microsoft.

- **Cmdlets.** The first time a cmdlet runs in a fresh runspace, PowerShell 5.1 sets it up, and that setup isn't safe when two runspaces do it at the same moment. With just two workers, the original project hung in roughly 1 run in 8. Every cmdlet tried could trigger it, down to `Start-Sleep` and `Out-Null`. Replacing every cmdlet on the worker side with .NET calls took that to 0 hangs in 50 stress runs. The kit's own worker-side functions follow the same rule.
- **`$script:` variables.** A function listed in `-SharedFunctionNames` is recreated inside the worker from its source text, so it's no longer attached to your script and its `$script:` points somewhere else. Inside a `.GetNewClosure()` block, `$script:` points at a private copy. Either way the read comes back empty, with no error.
- **Delegates.** When .NET calls a scriptblock through a delegate, PowerShell can hand the call to the runspace's own thread instead of running it on the spot. Nested, the inner call waits for a thread that is itself waiting on that call. It's timing-dependent: it showed up in about 1 or 2 runs in 100, and was only pinned down from process dumps.

## Process dispatch with groups

`Invoke-PkProcessBatch` covers a flat list. `Invoke-PkProcessDispatch` is the engine under it, for work that comes in groups (a folder of files, say) where something should happen when each group finishes:

```powershell
Invoke-PkProcessDispatch -MaxConcurrent 6 `
    -GroupProvider         { <# next group object, or $null when done #> } `
    -JobBuilder            { param($group)  <# hashtable job(s): @{ FilePath; Arguments; WorkingDirectory; ... } #> } `
    -JobFinalize           { param($job, $pending)  $r = Complete-PkProcess -Job $job; ... } `
    -JobAbortCleanup       { param($job)  <# delete a killed job's partial output #> } `
    -GroupCompleteCallback { param($group)  <# e.g. zip the folder #> }
```

All of these callbacks run on whichever thread called the dispatcher: the main thread normally, or the worker if you call it from inside a runspace job (in which case the worker rules apply to them).

- **`-GroupCompleteCallback` also runs for a group an abort cut short**, so you can record the jobs in it that did finish. Before doing anything irreversible there (zipping the folder, deleting sources), check `Test-PkCancelRequested` (or your own `-CancelToken`) and skip it if true.
- `-JobFinalize` is called once per finished job. Collect its exit code and output there with `Complete-PkProcess -Job $job`; the dispatcher disposes the process right after.
- Groups are pulled lazily, at most `-MaxQueueAhead` (default 3) ahead.
- A group can be any value: a hashtable, a path, a name. Each job gets its group as `$job.Group`.
- The dispatcher keeps its state on the job hashtables. Don't use these names for your own job fields: `GroupKey`, `SlotReleased`, `Proc`, `StdoutTask`, `StderrTask`, `Stopwatch`. (`Group` is yours if you set it yourself.)
- To retry a job or add follow-up work, enqueue job hashtables onto `$pending` inside `-JobFinalize`. They join the same group, and the group isn't complete until they've all finished.
- Supply `-JobStarter { param($job) ... }` to start jobs yourself. It must set `$job.Proc` and should return the job. A starter that is just `Start-PkProcess ...` works too: its result is folded into your job. Throw to report a job that couldn't start.
- Whatever your callbacks output is thrown away, apart from the return values listed here. They can't corrupt the dispatcher's result by accident.
- `-MaxConcurrent` can be a `SemaphoreSlim` shared by several dispatchers that must stay under one combined limit. It works inside workers, so two runspace jobs can each run a dispatcher against one shared budget.
- `-GroupReleaseCheck { param($group) }` makes a group with zero jobs keep its queue-ahead slot until the check returns true. Use it to stop one dispatcher racing ahead of another that it's paired with. The dispatcher doesn't return until every held group has been released.
- `-JobPollCompleted { param($job) }` replaces the default "has the process exited" check. Use it for a custom starter whose job isn't a plain process, or to give each job a time limit (see "Limits").
- `-AbortPollCallback { param($runningJobs) }` runs on every loop pass, with the jobs currently running.
- `-CancelToken` stops the dispatcher when cancelled. An abort stops it either way, without cancelling your token.
- An exception from one of your callbacks stops the dispatcher: running processes are killed and the exception is rethrown.
- Returns `@{ GroupResults; Aborted; ForceKilledCount; JobStarterFailedCount }`. `GroupResults` holds one `@{ GroupInfo; Completed; Aborted }` per group, where `GroupInfo` is the group value.

Closures: build every callback that uses your local variables with `{ ... }.GetNewClosure()`. Without it, a variable name that happens to match one inside the kit silently reads the kit's value instead of yours. And keep any state a callback changes in a hashtable (`$state = @{ Count = 0 }`, then `$state.Count++`). A plain variable assigned inside a closure doesn't stick between calls.

## Single processes

| Function | Use |
|---|---|
| `Invoke-PkProcessWithTimeout -FilePath -Arguments -TimeoutMs` | Run one program and wait, with a hard time limit (default 60s). Returns `@{ ExitCode; Stdout; Stderr; StreamTimedOut; StreamError }`. If it overruns, or the run is aborted, the program is killed and this **throws**; add `-IgnoreAbort` for a cleanup step that must finish anyway. |
| `Start-PkProcess -FilePath -Arguments` | Start one hidden, with output captured in the background. Returns `@{ Proc; StdoutTask; StderrTask; Stopwatch }`; throws if it can't start. |
| `Wait-PkProcess -Process -TimeoutMs` | Wait for exit with a timeout that can't overrun. Returns `$true` if it exited. |
| `Complete-PkProcess -Job` | Collect exit code and output from a finished one (`-Job` is what `Start-PkProcess` returned). Same result as `Invoke-PkProcessWithTimeout`. |

`Invoke-PkProcessWithTimeout` and `Start-PkProcess` also take `-WorkingDirectory`.

All four are safe in worker code.

## Messages

Workers can't safely write to the console. `Write-PkMessage "text" -Level Info|Warn|Error` works from anywhere: in a worker it's queued and delivered on the main thread. By default messages go to `Write-Host`. To route them into your own logging:

```powershell
Set-PkMessageHandler { param($Message, $Level) Write-MyLog $Message $Level }
```

The handler always runs on the main thread, so it can use anything. The kit's own notices (abort announcements, crashed workers, force-stops) go through the same handler. If your handler throws, the message is shown on the console instead and the run carries on. `Set-PkMessageHandler $null` restores the default.

## Abort

Inside `Invoke-PkRun { ... }`, Ctrl+C or closing the window:

1. stops new jobs from starting,
2. cancels the run's token (`Test-PkCancelRequested` turns true in workers),
3. waits for in-flight work (`-DrainTimeoutSeconds` / `-AbortTimeoutSeconds`, default 60),
4. force-stops whatever is left, calling `-JobAbortCleanup` for each killed or never-started process job.

A window close gets no waiting period: Windows allows only a few seconds, so leftovers are stopped straight away.

Two things to know:

- **Inside `Invoke-PkRun`, Ctrl+C no longer kills anything by itself.** It only raises a flag. The kit's engines watch that flag. A long step of your own in there has to check `Test-PkAbortSignal` now and then and stop when it's true, or Ctrl+C will seem to do nothing until that step ends.
- **An abort stays in force until it's reset.** `Invoke-PkRun` resets it at the start of each run. If you call an engine again outside `Invoke-PkRun` after an abort, it returns straight away with `Aborted = $true`. Call `Reset-PkAbortState` first if you mean to carry on.

`Invoke-PkRun` also turns off the console's QuickEdit mode for the length of the run (`-DisableQuickEdit $false` to opt out). With QuickEdit on, one stray click in the console window starts a text selection, and the script freezes for as long as the selection stays there. That looks exactly like a hang. It's turned back on afterwards if it was on before.

Other pieces: `Request-PkAbort` triggers the same abort from code. `Test-PkAbortSignal` asks whether one is under way. `Register-PkCancellationSource` adds your own `CancellationTokenSource` to the set an abort cancels (a `-Cts` or `-CancelToken` you pass to an engine is covered automatically). `Get-PkAbortTriggerLabel` says which kind of abort it was.

## Choosing limits

- **`-MaxConcurrent` for programs.** For programs that use one CPU core each, start at `[Environment]::ProcessorCount`. Many encoders (image, video, compression) already use several cores per file, so fewer copies at once is often as fast and uses less memory. Programs that mostly wait on disk or network can go higher. Try a few values on real work; the best number depends on the tool.
- **`-MaxParallel` for runspace jobs.** Same idea: the core count for CPU-heavy PowerShell work. Each runspace costs some memory and startup time, so very high values rarely help.
- **Several dispatchers at once** (for example, one per runspace job) should share one `SemaphoreSlim` as `-MaxConcurrent`, so their combined total stays under the limit you picked.

## Limits

- Windows PowerShell 5.1, Windows only (console and Job Object APIs).
- After changing `ParallelKit.ps1` itself, start a new PowerShell window. A session keeps the kit's compiled parts until it closes; the kit tells you if it finds an older copy loaded.
- One run at a time per process. The abort state is shared. A nested `Invoke-PkRun` just runs inside the outer one.
- A worker stuck inside a long .NET call can't be interrupted. Force-stop stops waiting for it and returns. The worker is NOT killed: once that call returns it can carry on to the end of its script. Before any step that can't be undone (deleting a source file, say), have the worker check `Test-PkCancelRequested` and skip the step if it's true.
- `Invoke-PkProcessBatch` and `Invoke-PkProcessDispatch` have no per-program time limit: a program that hangs holds its slot until it exits or the run is aborted. With the dispatcher you can add one through `-JobPollCompleted`, using the stopwatch the default starter puts on each job: `{ param($job) if ($job['Stopwatch'].Elapsed.TotalMinutes -gt 10) { try { $job['Proc'].Kill() } catch { } }; $job['Proc'].HasExited }`. The killed job then goes through `-JobFinalize` like any other, with a non-zero exit code.
- Programs run hidden, and there's no way to send them input. A program that stops to ask a question will sit there until it's killed.
- A program's output is collected in memory and handed over when it exits; there's no live line-by-line output. A program that prints gigabytes will use that much memory.

## Testing

`ParallelKit.Harness.ps1` is the test suite. It isn't needed at runtime. Run it in a fresh window (see "Limits" above):

```powershell
powershell -NoProfile -File .\ParallelKit.Harness.ps1
```

It uses real runspaces and real child processes (`cmd.exe`, `ping.exe`), with nothing mocked, so it takes about a minute. It prints a `[PASS]`/`[FAIL]` line per check and exits 0 only if everything passed. A few `message handler failed` lines in the output are expected: some checks break the message handler on purpose to test the fallback.

GitHub runs the same harness on Windows PowerShell 5.1 for every pull request and every change to `main`.

## License

MIT - see `LICENSE`.
