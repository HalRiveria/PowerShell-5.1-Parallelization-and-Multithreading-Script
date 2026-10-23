# ParallelKit

Parallel work for Windows PowerShell 5.1, in one file:

- **Runspace jobs** - run a PowerShell worker script many times in parallel.
- **Process dispatch** - run many external programs, a bounded number at a time.
- **Graceful abort** - Ctrl+C or closing the window finishes in-flight work and
  stops cleanly instead of killing the process mid-write.
- **No orphans** - child processes die with the script, even if it's force-closed.

It was pulled out of a separate project, where these pieces were
debugged against real hangs and deadlocks. It has no dependency on that project.

## Setup

Copy `ParallelKit.ps1` into your project and dot-source it:

```powershell
. "$PSScriptRoot\ParallelKit.ps1"
$null = Initialize-ParallelKit -MaxConcurrentProcesses 8
```

It works whether or not your script uses `Set-StrictMode`.

Dot-source it; don't `Import-Module` it. As a module it couldn't see the
functions you list in `-SharedFunctionNames`.

`Initialize-ParallelKit` is optional. It registers the Ctrl+C handler, sets
up child-process cleanup and sizes the thread pool up front; the engines set
up what they need on first use either way. It returns
`@{ AbortHandler; ChildProcessJob; ThreadPool }`, each `$true` if that part
worked (a part that fails also prints a warning).

`ParallelKit.Harness.ps1` is the test suite. It isn't needed at runtime.

## Run a list of programs

```powershell
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

`Invoke-PkProcessBatch` returns `@{ Results; Aborted; ForceKilledCount }`.
Each result is `@{ Command; ExitCode; Stdout; Stderr; StreamTimedOut; StreamError; StartError; Aborted }`,
with every field always present:

- `Command` is your original command hashtable, so extra keys like `Source`
  above come back with it.
- `StartError` is set when the program couldn't be started (not found, say).
- `Aborted` is `$true` for a command an abort killed or kept from starting.
- `StreamTimedOut` / `StreamError` mean the output may be incomplete. The
  output read gives up 15 seconds after the program exits, which only
  happens when a program it started is still holding the output open.

`-OnComplete` runs only for commands that actually ran. Check `Results` for
the ones that couldn't start or were aborted.

`Invoke-PkRun { ... }` is what makes Ctrl+C graceful. It also stops the PC
idle-sleeping until the run ends (`-KeepAwake $false` to opt out); the
display can still turn off. Without it the engines
still work, but Ctrl+C kills the process the normal way. See "Abort" below
for what it means for your own code inside the braces.

## Run PowerShell code in parallel

```powershell
function Get-FileSha { param($Path) ... }          # raw .NET only - see the rules below

$jobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($f in $files) { $jobs.Add(@{ Path = $f.FullName }) }
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

- Each job hashtable's keys become the worker's parameters.
- `-JobParams` takes a list or array of job hashtables. A single hashtable
  works too, so a list that happens to hold one job is fine.
- A worker runspace starts empty. Name every one of your functions it calls in
  `-SharedFunctionNames`. The kit's own worker functions are always there.
- Whatever the worker returns is handed to `-ResultHandler` on the main thread.
- `-NextJobProvider { ... }` can replace `-JobParams` to produce jobs lazily.
- `-JobCrashedHandler { param($err) ... }` is told when a worker throws.
- If one of your main-thread callbacks throws, the run stops: workers still
  going are told to stop and the exception comes out of the call.
- Returns `@{ ForceStoppedCount; CrashedCount; Aborted }`.

## The three rules for worker code

Worker code is the worker script, every function in `-SharedFunctionNames`, and
anything they call. Breaking these rules doesn't fail loudly. It hangs, or
quietly reads nothing.

1. **No `$script:` variables.** In a worker they can silently read as empty.
   Pass state in as job parameters. (`$script:` at the very top level of the
   worker script is fine; inside a function or a nested `{ }` block it isn't.)
2. **No cmdlets.** Two fresh runspaces calling the same cmdlet for the first
   time at the same moment can deadlock in PowerShell 5.1. Use .NET calls:
   `[System.IO.File]::Exists($p)` instead of `Test-Path`,
   `[System.Threading.Thread]::Sleep(100)` instead of `Start-Sleep`, a
   `foreach` loop instead of `ForEach-Object`, `Write-PkMessage` instead of
   `Write-Host`.
3. **No scriptblocks handed to .NET as delegates** (`[Func[...]]{ }`,
   `[Action]{ }`, `System.Lazy`, `ConcurrentDictionary.GetOrAdd($k, { })`).
   Nested, they deadlock. Use plain loops and `[System.Threading.Monitor]`.

`Test-PkWorkerSafety -WorkerScript $w -SharedFunctionNames $names` checks all
three, plus missing shared functions, and returns a list of findings. For
rule 3 it flags both written casts and scriptblocks passed straight into a
.NET call. Call it
from your tests, or pass `-CheckWorkerSafety` to `Invoke-PkRunspaceJobs` to
refuse to launch unsafe code. `# pk:ignore` on a line accepts a finding. It
can't see callbacks you pass to a worker as job parameters, or commands run
through a variable (`& $cmd`).

Callbacks that run on the main thread (`-ResultHandler`, `-PollCallback`,
`-NextJobProvider`, `-OnComplete`, the message handler) are not worker code
and can use anything.

## Process dispatch with groups

`Invoke-PkProcessBatch` covers a flat list. `Invoke-PkProcessDispatch` is the
engine under it, for work that comes in groups (a folder of files, say) where
something should happen when each group finishes:

```powershell
Invoke-PkProcessDispatch -MaxConcurrent 6 `
    -GroupProvider         { <# next group object, or $null when done #> } `
    -JobBuilder            { param($group)  <# hashtable job(s): @{ FilePath; Arguments; WorkingDirectory; ... } #> } `
    -JobFinalize           { param($job, $pending)  $r = Complete-PkProcess -Job $job; ... } `
    -JobAbortCleanup       { param($job)  <# delete a killed job's partial output #> } `
    -GroupCompleteCallback { param($group)  <# e.g. zip the folder #> }
```

- **`-GroupCompleteCallback` also runs for a group an abort cut short**, so
  you can record the jobs in it that did finish. Before doing anything
  irreversible there (zipping the folder, deleting sources), check
  `Test-PkCancelRequested` (or your own `-CancelToken`) and skip it if true.
- Groups are pulled lazily, at most `-MaxQueueAhead` (default 3) ahead.
- A group can be any value: a hashtable, a path, a name. Each job gets its
  group as `$job.Group`.
- The dispatcher keeps its state on the job hashtables. Don't use these names
  for your own job fields: `GroupKey`, `SlotReleased`, `Proc`, `StdoutTask`,
  `StderrTask`, `Stopwatch`. (`Group` is yours if you set it yourself.)
- To retry a job or add follow-up work, enqueue job hashtables onto
  `$pending` inside `-JobFinalize`. They join the same group, and the group
  isn't complete until they've all finished.
- Supply `-JobStarter { param($job) ... }` to start jobs yourself. It must set
  `$job.Proc` and should return the job. A starter that is just
  `Start-PkProcess ...` works too: its result is folded into your job. Throw to
  report a job that couldn't start.
- Whatever your callbacks output is thrown away, apart from the return values
  listed here. They can't corrupt the dispatcher's result by accident.
- `-MaxConcurrent` can be a `SemaphoreSlim` shared by several dispatchers that
  must stay under one combined limit. It works inside workers, so two runspace
  jobs can each run a dispatcher against one shared budget.
- `-GroupReleaseCheck { param($group) }` makes a group with zero jobs keep its
  queue-ahead slot until the check returns true. Use it to stop one dispatcher
  racing ahead of another that it's paired with. The dispatcher doesn't
  return until every held group has been released.
- `-JobPollCompleted { param($job) }` replaces the default "has the process
  exited" check, for a custom starter whose job isn't a plain process.
- `-AbortPollCallback { param($runningJobs) }` runs on every loop pass, with
  the jobs currently running.
- `-CancelToken` stops the dispatcher when cancelled. An abort stops it
  either way, without cancelling your token.
- An exception from one of your callbacks stops the dispatcher: running
  processes are killed and the exception is rethrown.
- Returns `@{ GroupResults; Aborted; ForceKilledCount; JobStarterFailedCount }`.
  `GroupResults` holds one `@{ GroupInfo; Completed; Aborted }` per group,
  where `GroupInfo` is the group value.

Closures: build every callback that uses your local variables with
`{ ... }.GetNewClosure()`. Without it, a variable name that happens to match
one inside the kit silently reads the kit's value instead of yours. And keep any state a callback changes in a hashtable
(`$state = @{ Count = 0 }`, then `$state.Count++`). A plain variable assigned
inside a closure doesn't stick between calls.

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

Workers can't safely write to the console. `Write-PkMessage "text" -Level Info|Warn|Error`
works from anywhere: in a worker it's queued and delivered on the main thread.
By default messages go to `Write-Host`. To route them into your own logging:

```powershell
Set-PkMessageHandler { param($Message, $Level) Write-MyLog $Message $Level }
```

The kit's own notices (abort announcements, crashed workers, force-stops) go
through the same handler. If your handler throws, the message is shown on the
console instead and the run carries on.

## Abort

Inside `Invoke-PkRun { ... }`, Ctrl+C or closing the window:

1. stops new jobs from starting,
2. cancels the run's token (`Test-PkCancelRequested` turns true in workers),
3. waits for in-flight work (`-DrainTimeoutSeconds` / `-AbortTimeoutSeconds`, default 60),
4. force-stops whatever is left, calling `-JobAbortCleanup` for each killed or never-started process job.

A window close gets no waiting period: Windows allows only a few seconds, so
leftovers are stopped straight away.

Two things to know:

- **Inside `Invoke-PkRun`, Ctrl+C no longer kills anything by itself.** It only
  raises a flag. The kit's engines watch that flag. A long step of your own in
  there has to check `Test-PkAbortSignal` now and then and stop when it's
  true, or Ctrl+C will seem to do nothing until that step ends.
- **An abort stays in force until it's reset.** `Invoke-PkRun` resets it at the
  start of each run. If you call an engine again outside `Invoke-PkRun` after
  an abort, it returns straight away with `Aborted = $true`. Call
  `Reset-PkAbortState` first if you mean to carry on.

Other pieces: `Request-PkAbort` triggers the same abort from code.
`Test-PkAbortSignal` asks whether one is under way. `Register-PkCancellationSource`
adds your own `CancellationTokenSource` to the set an abort cancels (a
`-Cts` or `-CancelToken` you pass to an engine is covered automatically).
`Get-PkAbortTriggerLabel` says which kind of abort it was.

## Limits

- Windows PowerShell 5.1, Windows only (console and Job Object APIs).
- After changing `ParallelKit.ps1` itself, start a new PowerShell window. A
  session keeps the kit's compiled parts until it closes; the kit tells you
  if it finds an older copy loaded.
- One run at a time per process. The abort state is shared. A nested
  `Invoke-PkRun` just runs inside the outer one.
- A worker stuck inside a long .NET call can't be interrupted. Force-stop
  stops waiting for it and returns. The worker is NOT killed: once that call
  returns it can carry on to the end of its script. Before any step that can't
  be undone (deleting a source file, say), have the worker check
  `Test-PkCancelRequested` and skip the step if it's true.

## License

MIT - see `LICENSE`.
