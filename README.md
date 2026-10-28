# ParallelKit

[![Tests](https://github.com/HalRiveria/PowerShell-ParallelKit/actions/workflows/tests.yml/badge.svg)](https://github.com/HalRiveria/PowerShell-ParallelKit/actions/workflows/tests.yml)

Run thousands of command-line programs, or blocks of PowerShell code, in parallel from Windows PowerShell 5.1, and stop cleanly when you press Ctrl+C. One file, nothing to install.

- **Process dispatch** - run many external programs, a set number at a time, with their output captured.
- **Runspace jobs** - run a PowerShell worker script many times in parallel.
- **Graceful abort** - Ctrl+C lets in-flight work finish and stops cleanly, instead of killing everything mid-write. Closing the window stops what's left straight away, since Windows allows only a few seconds.
- **No orphans** - programs the script started die with it, even if it's force-closed.

It was pulled out of [Manga Conversion Script](https://github.com/HalRiveria/Manga-Conversion-Script), but has no dependencies on that project.

Built with Claude Code.

**Contents:** [Quick start](#quick-start) · [Who it's for](#who-its-for) · [Why Not Use X?](#why-not-use-x) · [Setup](#setup) · [Run a list of programs](#run-a-list-of-programs) · [Run PowerShell code in parallel](#run-powershell-code-in-parallel) · [The two rules for worker code](#the-two-rules-for-worker-code) · [Process dispatch with groups](#process-dispatch-with-groups) · [Single processes](#single-processes) · [Messages](#messages) · [Abort](#abort) · [Choosing limits](#choosing-limits) · [Limits](#limits) · [Testing](#testing) · [FAQ](#faq)

## Quick start

Most uses are this: a list of command-line programs, run a few at a time, where Ctrl+C lets the running ones finish instead of cutting them off.

```powershell
# In a saved script. At the prompt, $PSScriptRoot is empty: use . .\ParallelKit.ps1 instead.
. "$PSScriptRoot\ParallelKit.ps1"

$commands = foreach ($f in Get-ChildItem *.png) {
    @{ FilePath = 'cjxl.exe'; Arguments = (ConvertTo-PkArgumentString @($f.FullName, "$($f.FullName).jxl")) }
}
$batch = Invoke-PkRun { Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 6 }

foreach ($r in $batch.Results) {
    if ($r.Aborted) { continue }   # stopped by Ctrl+C before it finished; no exit code
    if ($r.ExitCode -ne 0) { Write-Warning ('Failed: ' + $r.Command.Arguments) }
}
```

That's all you need for this case. The worker rules, closures and callback details further down don't apply to it: they only matter for running PowerShell code in parallel (`Invoke-PkRunspaceJobs`) or for the group dispatcher. [Run a list of programs](#run-a-list-of-programs) covers the result fields and options.

## Who it's for

Scripts that have to run on Windows PowerShell 5.1, the version built into Windows 10 (1607 and later), Windows 11 and Windows Server 2016 and later. Usually that's because PowerShell 7 isn't installed or isn't allowed on the machines involved, or because the script has to run anywhere without asking anyone to install anything.

The typical job is batch work over lots of files with a command-line tool: converting images, audio or video, compressing archives, running a check or build step per file. That's what the process side is built for, and it's where most of the kit's care has gone.

For plain parallel loops of PowerShell code, other tools are simpler (see [Why Not Use X?](#why-not-use-x)). Reach for ParallelKit when you need any of these:

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

Wrap any of them in `Invoke-PkRun { ... }` to get graceful Ctrl+C. (For `Invoke-PkProcessWithTimeout` that means the program is killed and the call throws, instead of the whole script dying.)

## Why Not Use X?

For running PowerShell code in parallel, most of these are fine and some are simpler. ParallelKit is mainly about running external programs, and about what happens when a run is stopped partway through.

- **PowerShell 7's `ForEach-Object -Parallel`.** The easy answer if you can use PowerShell 7. ParallelKit is for scripts and machines that are stuck on 5.1.
- **`Start-Job`.** Built in, but each job is a whole new `powershell.exe` process, so every job costs noticeable startup time and memory, and what it returns comes back as serialized copies (properties only, no methods). 5.1's `Start-Job` has no throttle either, so you write the wait-for-a-free-slot loop yourself. Fine for a handful of long jobs, poor for thousands of short ones.
- **ThreadJob (`Start-ThreadJob`).** Runs jobs as runspaces in the same process, with a `-ThrottleLimit`. On 5.1 it's the best fit for plain parallel scriptblocks, if you can install a module from the PowerShell Gallery (it ships with PowerShell 7, not 5.1).
- **PoshRSJob (`Start-RSJob`).** A community module from the Gallery, also runspace-based, with a `-Throttle` limit and a job-style interface. For this purpose it has the same strengths and gaps as ThreadJob.
- **A runspace pool by hand** (`[runspacefactory]::CreateRunspacePool`). That's what `Invoke-PkRunspaceJobs` is built on. It works, but you end up writing the polling loop, error collection, cancellation and cleanup yourself, which is most of what this file is.
- **Workflows (`foreach -parallel`).** Still in 5.1, but they use a restricted version of the language, start slowly, and were dropped from PowerShell 6 and later. Not worth starting anything new on.
- **`Start-Process` in a loop.** Starts programs without waiting, but can only send their output to files, and the throttling and waiting are up to you. Using `System.Diagnostics.Process` directly gets output into memory, but reading stdout and then stderr the simple way deadlocks once a program fills the pipe you aren't reading. The kit reads both in the background.
- **`Invoke-Command -AsJob` against localhost.** Needs PowerShell remoting enabled (on by default only on Windows Server), and connecting to your own machine needs an elevated session, all for no gain on one machine.

What none of them do for you:

- On Ctrl+C, let running work finish (up to a time limit), then stop what's left and call your cleanup for each job that was killed. A window close does the same without the wait.
- Kill the programs your script started if the script itself is killed. Windows doesn't do that on its own: a process's children keep running after it dies.
- Run external programs directly, with a cap and captured output, instead of tying up a PowerShell thread to wait on each one.
- Work in groups, with retries and a step when each group finishes.

## Setup

Requires Windows and Windows PowerShell 5.1. Copy `ParallelKit.ps1` into your project and dot-source it:

```powershell
. "$PSScriptRoot\ParallelKit.ps1"
$null = Initialize-ParallelKit -MaxConcurrentProcesses 8
```

If you downloaded the file, Windows marks it as coming from the internet and your execution policy may refuse to load it. Run `Unblock-File .\ParallelKit.ps1` once to clear that.

It works whether or not your script uses `Set-StrictMode`.

Dot-source it; don't `Import-Module` it. As a module it couldn't see the functions you list in `-SharedFunctionNames`.

The kit's functions are also defined globally, so they stay available for the rest of that PowerShell session, and a `.GetNewClosure()` block can call them however your script was started.

`Initialize-ParallelKit` is optional. It registers the Ctrl+C handler, sets up child-process cleanup and sizes the thread pool up front; the engines set up what they need on first use either way. It returns an object with `AbortHandler`, `ChildProcessJob` and `ThreadPool`, each `$true` if that part worked (a failed abort handler or child-process cleanup also prints a warning).

Each public function has built-in help: `Get-Help Invoke-PkProcessBatch -Full` shows its parameters, their defaults, what it returns and an example.

## Run a list of programs

```powershell
# Any command-line tool works. cjxl is a JPEG XL image encoder.
$commands = foreach ($f in Get-ChildItem *.png) {
    @{ FilePath = 'cjxl.exe'; Arguments = (ConvertTo-PkArgumentString @($f.FullName, "$($f.FullName).jxl")); Source = $f }
}
$batchParams = @{
    Commands      = $commands
    MaxConcurrent = 6
    OnComplete    = {
        param($command, $result)
        if ($result.ExitCode -ne 0) { Write-PkMessage "FAILED: $($command.Source.Name)" -Level Error }
    }
}
$batch = Invoke-PkRun { Invoke-PkProcessBatch @batchParams }
```

Long parameter lists in these examples use splatting (`@batchParams`) instead of trailing backticks: it's easier to read, and a stray space after a backtick can't break it.

Each command is a hashtable with `FilePath`, `Arguments` and optionally `WorkingDirectory`, plus any keys of your own. `Arguments` is passed to the program as one string, exactly as written. `ConvertTo-PkArgumentString @(...)` builds that string from a list, quoting each argument so the program gets exactly that list back, spaces, quotes and trailing backslashes included. It follows the rules most Windows programs use; `cmd.exe /c` parses its own way. Programs run hidden, with their output captured.

`Invoke-PkProcessBatch` returns an object with `Results`, `Aborted` and `ForceKilledCount`. Each result is an object with `Command`, `ExitCode`, `Stdout`, `Stderr`, `StreamTimedOut`, `StreamError`, `StartError`, `Aborted` and `TimedOut`, every field always present, so `$batch.Results | Format-Table` reads well:

- `Command` is your original command hashtable, so extra keys like `Source` above come back with it.
- `ExitCode` is whatever the program returned. The kit doesn't treat a non-zero code as a failure; that's for you to decide.
- `StartError` is set when the program couldn't be started (not found, say).
- `Aborted` is `$true` for a command an abort killed or kept from starting.
- `TimedOut` is `$true` for a program `-TimeoutSeconds` killed.
- `StreamTimedOut` / `StreamError` mean the output may be incomplete. The output read gives up 15 seconds after the program exits, which only happens when a program it started is still holding the output open.

`Results` is in the order commands finished, not the order you gave them. Use `Command` to match them up.

`-OnComplete` runs as each command finishes, but only for commands that actually ran. Check `Results` for the ones that couldn't start or were aborted. Defaults: `-MaxConcurrent` 4, `-AbortTimeoutSeconds` 60 (how long Ctrl+C waits for running programs), `-TimeoutSeconds` 0 (no limit).

`-TimeoutSeconds 600` kills any program still running after 10 minutes. Its result has `TimedOut = $true`, still goes through `-OnComplete`, and the rest of the batch carries on. The default, 0, means no limit. Any programs it started are killed with it.

Output is decoded in the console's code page unless you say otherwise, which is right for Windows' own tools. Many cross-platform tools write UTF-8 instead, and their non-ASCII output (accented or Japanese file names, say) comes back garbled. Pass `-OutputEncoding 'utf-8'` for the whole batch, or put an `OutputEncoding` key on one command. It also takes a code page number (`65001`, `437`) or a `[System.Text.Encoding]`, and the same option exists on `Invoke-PkProcessWithTimeout` and `Start-PkProcess` (and as a job key for the dispatcher's default starter).

`Invoke-PkRun { ... }` is what makes Ctrl+C graceful. Whatever the block outputs is passed through, so `$batch` above gets the batch result. It also stops the PC idle-sleeping until the run ends (`-KeepAwake $false` to opt out); the display can still turn off. Without `Invoke-PkRun` the engines still work, but Ctrl+C kills the script the normal way. See "Abort" below for what it means for your own code inside the braces.

## Run PowerShell code in parallel

```powershell
# Worker code can use cmdlets - see "The two rules" below for what it can't do.
function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$jobs = [System.Collections.Generic.List[hashtable]]::new()
foreach ($f in Get-ChildItem -File) { $jobs.Add(@{ Path = $f.FullName }) }
$shaByPath = @{}

$jobsParams = @{
    MaxParallel         = 4
    JobParams           = $jobs
    SharedFunctionNames = @('Get-FileSha')
    WorkerScript        = {
        param([string]$Path)
        if (Test-PkCancelRequested) { return }
        Write-PkMessage "hashing $Path"
        return @{ Path = $Path; Sha = (Get-FileSha -Path $Path) }
    }
    ResultHandler       = { param($r) $shaByPath[$r.Path] = $r.Sha }.GetNewClosure()
}
$out = Invoke-PkRun { Invoke-PkRunspaceJobs @jobsParams }
```

Each worker runs in its own runspace: a separate PowerShell session inside the same process, with its own variables and functions. That separation is what makes running them at the same time safe, and also why a worker can't see your script's variables or functions unless you hand them over.

- Each job hashtable's keys become the worker's parameters. The worker's `param()` block must declare every key. A key it doesn't declare is an error; with a fixed `-JobParams` list it's caught before any worker starts.
- If the worker declares a `$CancelToken` parameter, it gets the run's cancellation token.
- `-JobParams` takes a list or array of job hashtables. A single hashtable works too, so a list that happens to hold one job is fine.
- A worker runspace starts empty. Name every one of your functions it calls in `-SharedFunctionNames`. The kit's own worker functions are always there, and cmdlets and functions from installed modules load on their own. A module you imported by path isn't installed, so list its functions too (or put it on `$env:PSModulePath`).
- Whatever the worker returns is handed to `-ResultHandler` on the main thread, once per object returned.
- `-NextJobProvider { ... }` can replace `-JobParams` to produce jobs lazily: it's called on the main thread for the next job hashtable, and returns `$null` when there are no more.
- `-PollCallback { ... }` runs on the main thread on every loop pass, for progress display and the like.
- `-JobCrashedHandler { param($err) ... }` is told when a worker throws. That job's result handler isn't called.
- `-MaxParallel` has no default; you choose it. `-DrainTimeoutSeconds` (how long Ctrl+C waits for running workers) defaults to 60.
- If `-ResultHandler`, `-PollCallback` or `-NextJobProvider` throws, the run stops: workers still going are told to stop and the exception comes out of the call.
- Returns an object with `ForceStoppedCount`, `CrashedCount` and `Aborted`.

## The two rules for worker code

These only apply if you run PowerShell code in parallel with `Invoke-PkRunspaceJobs` (or call a dispatcher from inside one of its workers). Running external programs with `Invoke-PkProcessBatch` or `Invoke-PkProcessDispatch` on the main thread never touches them.

Worker code is the worker script, every function in `-SharedFunctionNames`, and anything they call. Breaking these rules doesn't fail loudly. It hangs, crashes, or quietly reads nothing.

1. **No `$script:` variables.** In a worker they can silently read as empty. Pass state in as job parameters. (`$script:` at the very top level of the worker script is fine; inside a function or a nested `{ }` block it isn't.)
2. **A scriptblock only runs in the runspace that made it.** Don't hand one to .NET as a delegate (`[Func[...]]{ }`, `[Action]{ }`, a `System.Lazy` factory, `ConcurrentDictionary.GetOrAdd($k, { })`, a comparer, an event or task callback): use plain loops and `[System.Threading.Monitor]` instead. Don't pass one in as a job value either: pass its text (`$sb.ToString()`) and rebuild it in the worker with `[scriptblock]::Create($text)`.

Everything else is fine in a worker, cmdlets included. Callbacks that run on the main thread (`-ResultHandler`, `-PollCallback`, `-NextJobProvider`, `-OnComplete`, the message handler) are not worker code and can use anything.

`Invoke-PkRunspaceJobs` checks both rules before it starts anything, and refuses to launch code that breaks them, naming the line or the job key. Pass `-CheckWorkerSafety:$false` to turn that off. The code check is also available on its own as `Test-PkWorkerSafety -WorkerScript $w -SharedFunctionNames $names`, which returns a list of findings (including functions the worker calls but you didn't share), for use in your own tests. For rule 2 it flags written casts, and scriptblocks passed into a .NET method or constructor, either written in the call or through a variable they were assigned to. `# pk:ignore` on a line accepts a finding. Storing a scriptblock in a collection (`$list.Add($sb)`, `$queue.Enqueue($sb)`) isn't flagged, since that makes no delegate. It can't see commands run through a variable (`& $cmd`), a collection typed to hold delegates (`List[Func[object]]`, whose `.Add` converts), or a scriptblock buried more than three levels deep in a job value.

### Why these rules exist

Both were found chasing real, intermittent failures, and neither is in Microsoft's documentation as far as we could find.

- **`$script:` variables.** A function listed in `-SharedFunctionNames` is recreated inside the worker from its source text, so it's no longer attached to your script and its `$script:` points somewhere else. Inside a `.GetNewClosure()` block, `$script:` points at a private copy. Either way the read comes back empty, with no error.
- **Scriptblocks.** A scriptblock belongs to the runspace that created it, and runs against that runspace's session state wherever it's called from ([PowerShell issue #4003](https://github.com/PowerShell/PowerShell/issues/4003)). When a delegate makes .NET call one from another runspace's thread, PowerShell can hand the call back to the owning runspace's thread. If that thread is itself waiting, and the scriptblock runs another scriptblock inside it (a `Where-Object { }` filter, a nested delegate), it deadlocks. Even when it doesn't deadlock, two threads using one session state at once can crash the process. A scriptblock passed in as a job value is the same case: in stress tests, 8 workers running one passed from the main thread broke 88 of 90 runs, usually by corrupting the main thread's session state so the kit's own functions vanished mid-run, even when the scriptblock held nothing but .NET calls. Passed as text and rebuilt in the worker, the same code ran clean in all 30 runs.

## Process dispatch with groups

`Invoke-PkProcessBatch` covers a flat list. `Invoke-PkProcessDispatch` is the engine under it, for work that comes in groups (a folder of files, say) where something should happen when each group finishes:

```powershell
$dispatchParams = @{
    MaxConcurrent         = 6
    GroupProvider         = { <# next group object, or $null when done #> }
    JobBuilder            = { param($group)  <# hashtable job(s): @{ FilePath; Arguments; WorkingDirectory; ... } #> }
    JobFinalize           = { param($job, $pending)  $r = Complete-PkProcess -Job $job; <# ... #> }
    JobAbortCleanup       = { param($job)  <# delete a killed job's partial output #> }
    GroupCompleteCallback = { param($group)  <# e.g. zip the folder #> }
}
$dispatch = Invoke-PkProcessDispatch @dispatchParams
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
- `-GroupReleaseCheck { param($group) }` makes a group with zero jobs keep its queue-ahead slot until the check returns true. Use it to stop one dispatcher racing ahead of another that it's paired with. The dispatcher doesn't return until every held group has been released, unless the run is cancelled or aborted.
- `-JobPollCompleted { param($job) }` replaces the default "has the process exited" check. Use it for a custom starter whose job isn't a plain process, or to give each job a time limit (see "Limits").
- `-AbortPollCallback { param($runningJobs) }` runs on every loop pass, with the jobs currently running.
- `-CancelToken` stops the dispatcher when cancelled. An abort stops it either way, without cancelling your token.
- An exception from one of your callbacks stops the dispatcher: running processes are killed and the exception is rethrown.
- Returns an object with `GroupResults`, `Aborted`, `ForceKilledCount` and `JobStarterFailedCount`. `GroupResults` holds one object with `GroupInfo`, `Completed` and `Aborted` per group, where `GroupInfo` is the group value.

Closures: build every callback that uses your local variables with `{ ... }.GetNewClosure()`. Without it, a variable name that happens to match one inside the kit silently reads the kit's value instead of yours. And keep any state a callback changes in a hashtable (`$state = @{ Count = 0 }`, then `$state.Count++`). A plain variable assigned inside a closure doesn't stick between calls. A closure can't see functions your script defines when the script is run from a prompt (`.\script.ps1`); the kit's own functions always work, but define any of yours that a closure calls as `function global:Get-Thing { ... }`.

## Single processes

| Function | Use |
|---|---|
| `Invoke-PkProcessWithTimeout -FilePath -Arguments -TimeoutMs` | Run one program and wait, with a hard time limit (default 60s). Returns an object with `ExitCode`, `Stdout`, `Stderr`, `StreamTimedOut` and `StreamError`. If it overruns, or the run is aborted, the program is killed and this **throws**; add `-IgnoreAbort` for a cleanup step that must finish anyway. |
| `ConvertTo-PkArgumentString @(args)` | Join a list of arguments into one correctly quoted command line, for any `-Arguments` / `Arguments` value. |
| `Start-PkProcess -FilePath -Arguments` | Start one hidden, with output captured in the background. Returns `@{ Proc; StdoutTask; StderrTask; Stopwatch }`; throws if it can't start. |
| `Wait-PkProcess -Process -TimeoutMs` | Wait for exit with a timeout that can't overrun. Returns `$true` if it exited. |
| `Complete-PkProcess -Job` | Collect exit code and output from a finished one (`-Job` is what `Start-PkProcess` returned). Same result as `Invoke-PkProcessWithTimeout`. |
| `Stop-PkProcessTree -Process` | Kill one or more programs and every program they started, in one `taskkill` call. For one program, returns `$false` if it had already exited. |

`Invoke-PkProcessWithTimeout` and `Start-PkProcess` also take `-WorkingDirectory`.

All four are safe in worker code.

## Messages

Workers can't safely write to the console. `Write-PkMessage "text" -Level Info|Warn|Error` works from anywhere: in a worker it's queued and delivered on the main thread. By default messages go to `Write-Host`. To route them into your own logging:

```powershell
Set-PkMessageHandler { param($Message, $Level) Write-MyLog $Message $Level }
```

The handler always runs on the main thread, so it can use anything. The kit's own notices (abort announcements, crashed workers, force-stops) go through the same handler. If your handler throws, the message is shown on the console instead and the run carries on. `Set-PkMessageHandler $null` restores the default.

## Abort

Inside `Invoke-PkRun { ... }`, Ctrl+C:

1. stops new jobs from starting,
2. cancels the run's token (`Test-PkCancelRequested` turns true in workers),
3. waits for in-flight work (`-DrainTimeoutSeconds` / `-AbortTimeoutSeconds`, default 60),
4. force-stops whatever is left, calling `-JobAbortCleanup` for each killed or never-started process job.

Closing the window does the same minus step 3: Windows allows only a few seconds, so leftovers are stopped straight away.

Three things to know:

- **Inside `Invoke-PkRun`, Ctrl+C no longer kills anything by itself.** It only raises a flag. The kit's engines watch that flag. A long step of your own in there has to check `Test-PkAbortSignal` now and then and stop when it's true, or Ctrl+C will seem to do nothing until that step ends.
- **An abort stays in force until it's reset.** `Invoke-PkRun` resets it at the start of each run. If you call an engine again outside `Invoke-PkRun` after an abort, it returns straight away with `Aborted = $true`. Call `Reset-PkAbortState` first if you mean to carry on.
- **Your script carries on after an abort.** The engines return with `Aborted = $true` and the rest of your script runs. If an abort should end it, say so: `if ($batch.Aborted) { exit 1 }`.

`Invoke-PkRun` also turns off the console's QuickEdit mode for the length of the run (`-DisableQuickEdit $false` to opt out). With QuickEdit on in the classic console window, one stray click starts a text selection, and the script freezes at its next console write until the selection is cleared. That looks exactly like a hang. It's turned back on afterwards if it was on before.

The block you give `Invoke-PkRun` runs inside it, so a variable of yours named like one of its own (`$ScriptBlock`, `$KeepAwake`, `$DisableQuickEdit`) reads its value instead of yours. Add `.GetNewClosure()` to the block if that could happen.

Other pieces: `Request-PkAbort` triggers the same abort from code. `Test-PkAbortSignal` asks whether one is under way. `Register-PkCancellationSource` adds your own `CancellationTokenSource` to the set an abort cancels (a `-Cts` you pass to `Invoke-PkRunspaceJobs` is added automatically; a `-CancelToken` you pass to the dispatcher isn't cancelled by an abort, but the dispatcher stops either way). `Get-PkAbortTriggerLabel` says which kind of abort it was.

## Choosing limits

- **`-MaxConcurrent` for programs.** For programs that use one CPU core each, start at `[Environment]::ProcessorCount`. Many encoders (image, video, compression) already use several cores per file, so fewer copies at once is often as fast and uses less memory. Programs that mostly wait on disk or network can go higher. Try a few values on real work; the best number depends on the tool.
- **`-MaxParallel` for runspace jobs.** Same idea: the core count for CPU-heavy PowerShell work. Each runspace costs some memory and startup time, so very high values rarely help.
- **Several dispatchers at once** (for example, one per runspace job) should share one `SemaphoreSlim` as `-MaxConcurrent`, so their combined total stays under the limit you picked.

## Limits

- Windows PowerShell 5.1, Windows only (console and Job Object APIs).
- Run it in a PowerShell console window or an editor's terminal (graceful Ctrl+C tested in Windows Terminal and Visual Studio's built-in terminal). The Windows PowerShell ISE isn't supported: tested there, the kit loads and runs, but the ISE has no console, so Ctrl+C stops the script outright, with no graceful drain and no cleanup callbacks.
- It needs FullLanguage mode, since it compiles a little C# with `Add-Type` when loaded. On a machine locked down to Constrained Language Mode (usually by AppLocker or Windows Defender Application Control), loading it fails with a message saying so. Some endpoint security products also flag scripts that compile code calling Windows APIs at runtime; if yours blocks the kit, that's the likely reason.
- After changing `ParallelKit.ps1` itself, start a new PowerShell window. A session keeps the kit's compiled parts until it closes; the kit tells you if it finds an older copy loaded.
- One run at a time per process. The abort state is shared. A nested `Invoke-PkRun` just runs inside the outer one.
- A worker stuck inside a long .NET call can't be interrupted. Force-stop stops waiting for it and returns. The worker is NOT killed: once that call returns it can carry on to the end of its script. Before any step that can't be undone (deleting a source file, say), have the worker check `Test-PkCancelRequested` and skip the step if it's true.
- `Invoke-PkProcessDispatch` has no per-program time limit (`Invoke-PkProcessBatch` has `-TimeoutSeconds`): a program that hangs holds its slot until it exits or the run is aborted. You can add one through `-JobPollCompleted`, using the stopwatch the default starter puts on each job: `{ param($job) if ($job['Stopwatch'].Elapsed.TotalMinutes -gt 10) { $null = Stop-PkProcessTree -Process $job['Proc'] }; $job['Proc'].HasExited }`. The killed job then goes through `-JobFinalize` like any other, with a non-zero exit code.
- Programs run hidden, and there's no way to send them input. A program that stops to ask a question will sit there until it's killed.
- A program's output is collected in memory and handed over when it exits; there's no live line-by-line output. A program that prints gigabytes will use that much memory.

## Testing

`ParallelKit.Harness.ps1` is the test suite. It isn't needed at runtime. Run it in a fresh window (see "Limits" above):

```powershell
powershell -NoProfile -File .\ParallelKit.Harness.ps1
```

It uses real runspaces and real child processes (`cmd.exe`, `ping.exe`), with nothing mocked, so it takes about a minute. It prints a `[PASS]`/`[FAIL]` line per check and exits 0 only if everything passed. A few `message handler failed` lines in the output are expected: some checks break the message handler on purpose to test the fallback.

GitHub runs the same harness on Windows PowerShell 5.1 for every pull request and every change to `main`.

## FAQ

**Can I use cmdlets in worker code?**

Yes. What a worker can't do is run a scriptblock that came from another runspace: one handed to .NET as a delegate, or one passed in as a job value. [The two rules](#the-two-rules-for-worker-code) cover it, and the kit checks for both before it starts.

**Do ThreadJob and PoshRSJob have the same scriptblock problem?**

It hasn't been tested with them. The cause is in PowerShell itself, not in this kit: a scriptblock stays tied to the runspace that made it. So any runspace-based tool that lets a scriptblock cross from one runspace to another can hit it. This kit refuses to launch when it sees one.

**Does it work in PowerShell 7, or on Linux or macOS?**

It's written for and tested on Windows PowerShell 5.1 only. Ctrl+C handling, child-process cleanup and keep-awake all use Windows APIs, so Linux and macOS are out. On PowerShell 7 for Windows it isn't tested, and `ForEach-Object -Parallel` covers most needs there anyway.

**Does it need admin rights?**

No. Nothing it does needs elevation.

**Why a file to dot-source instead of a module?**

As a module it couldn't find the functions you list in `-SharedFunctionNames`, since a module has its own scope. It's also one file you can copy into a project and keep at a known version, with nothing to install on machines where installing modules isn't allowed.

**What happens to running programs when I press Ctrl+C?**

Inside `Invoke-PkRun`, no new ones start, and the running ones get up to 60 seconds by default to finish. Anything still running after that is killed, and `-JobAbortCleanup` is called for each so you can delete its partial output. See [Abort](#abort).

**And if the script is killed outright, from Task Manager say?**

The programs it started are killed with it, through a Windows Job Object. There's no waiting period and no cleanup callback in that case, so partial output files can be left behind.

**Can I show progress?**

Yes. `-OnComplete` (batch) and `-PollCallback` (runspace jobs) run on the main thread, so `Write-Progress` or anything else works there. What you can't get is a program's output line by line while it runs: it's handed over when the program exits.

**How many should I run at once?**

Start from the CPU core count and measure. [Choosing limits](#choosing-limits) has more.

**Can I pipe into it?**

No. The engines take a list of hashtables (`-Commands`, `-JobParams`) rather than pipeline input, because each job needs several named values and the kit wants the whole list (or a provider for it) before it starts. Build the list with `foreach`, as the examples do: `$commands = foreach ($f in Get-ChildItem *.png) { @{ FilePath = ...; Arguments = ... } }`.

**Which functions are meant to be used?**

The ones in this README: the engines, the [single-process functions](#single-processes), and the abort and message functions named in their sections. Dot-sourcing also brings in internal helpers (`Invoke-PkProcessDispatchCore`, `Get-PkCommandKind` and so on), which show up in tab completion. Those can change between versions; don't call them.

**Does a program I start get my Ctrl+C too?**

No. Programs start without a window, in a hidden console of their own, so Ctrl+C in your window never reaches them. That's what lets them finish while the kit drains. When it does need to stop one (a timeout, or an abort's force-stop), the kit kills it along with anything it started.

**Was this written by AI?**

It was built with Claude Code, as the top of this page says. The worker rules and abort behaviour come from hangs and bugs reproduced in real runs of the original project, and the test harness runs real processes and runspaces, with nothing mocked, on every change.

## Bugs and questions

Open an [issue](https://github.com/HalRiveria/PowerShell-ParallelKit/issues) with what you ran, what happened, and your Windows and PowerShell versions (`$PSVersionTable`).

## License

MIT - see `LICENSE`.
