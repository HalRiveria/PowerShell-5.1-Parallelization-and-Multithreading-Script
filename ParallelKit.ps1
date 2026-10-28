# ParallelKit - parallel runspace jobs, bounded external-process dispatch, and
# graceful Ctrl+C/window-close handling for Windows PowerShell 5.1.
#
# Version 2.0 - https://github.com/HalRiveria/PowerShell-ParallelKit
# Copyright (c) 2026 HalRiveria. MIT License: keep this notice with any copy;
# the full text is in LICENSE in the repository.
#
# Use:   . "<path>\ParallelKit.ps1"     (dot-source it; do NOT Import-Module it)
# Read README.md first - the two worker-code rules there are what keep this
# from hanging or crashing.
#
# Works under Set-StrictMode: job hashtables are read as $job['Name'], never
# $job.Name, because under strict mode the dot form THROWS for a key that
# isn't there yet. Keep it that way when editing.
#
# State lives in the static [PkState] class, never in $script: variables - a
# function called from inside a .GetNewClosure()'d block can see an empty
# $script: scope, and a static has no scope to lose.

# Everything below needs Add-Type, which Constrained Language Mode blocks with
# an error that doesn't say why. Say why.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw ("ParallelKit: this PowerShell session runs in " + $ExecutionContext.SessionState.LanguageMode + " mode, but the kit needs FullLanguage " +
        "(it compiles C# with Add-Type). This is usually set by AppLocker or Windows Defender Application Control policy. " +
        "Ask whoever manages the machine to allow this script, or run it where that policy doesn't apply.")
}

# ==============================================================================
#  Native types (guarded so the file can be dot-sourced more than once)
# ==============================================================================

if (-not ([System.Management.Automation.PSTypeName]'PkConsoleCtrl').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class PkConsoleCtrl
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Set by the handler (or Request-PkAbort); polled by PowerShell code.
    public static volatile bool AbortRequested = false;
    public static volatile bool IsCloseEvent   = false;   // true = window close/logoff/shutdown, false = Ctrl+C

    // The handler only intercepts while a run is active. Outside a run,
    // Ctrl+C and closing the window behave exactly as they normally would.
    public static volatile bool RunActive = false;

    // The handler parks on this until the main thread finishes draining.
    public static readonly ManualResetEventSlim DrainComplete = new ManualResetEventSlim(false);
    public static int DrainWaitMs = 65000;   // keep above the drain timeout you use

    private static HandlerRoutine _handler;   // strong ref so the GC can't collect it
    public static bool LastRegisterSucceeded = false;

    public static void Register()
    {
        // SetConsoleCtrlHandler is additive - drop the previous delegate
        // first so a second Register() can't leave an unrooted one behind.
        if (_handler != null) { SetConsoleCtrlHandler(_handler, false); }
        _handler = new HandlerRoutine(Handler);
        LastRegisterSucceeded = SetConsoleCtrlHandler(_handler, true);
    }

    private static bool Handler(uint ctrlType)
    {
        // 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (!RunActive) { return false; }
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            // IsCloseEvent BEFORE AbortRequested: a poller that sees
            // AbortRequested must already see the right IsCloseEvent.
            IsCloseEvent   = (ctrlType == 2 || ctrlType == 5 || ctrlType == 6);
            AbortRequested = true;
            DrainComplete.Wait(DrainWaitMs);
            return true;   // suppress the default OS action
        }
        return false;
    }
}

// Keeps the PC from idle-sleeping while a run is going. Per-thread: lifted
// by the same thread that set it, and dropped by Windows if the process ends.
public static class PkSleepBlock
{
    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);
    public static bool Block()   { return SetThreadExecutionState(0x80000000u | 0x00000001u) != 0; }
    public static bool Unblock() { return SetThreadExecutionState(0x80000000u) != 0; }
}

// Main-thread bookkeeping. Static on purpose - see the note at the top of
// ParallelKit.ps1.
public static class PkState
{
    public static bool AbortLatched = false;
    public static bool CloseAbort   = false;
    public static object MessageHandler = null;   // a PowerShell scriptblock, or null for the default
    public static volatile bool ThreadPoolRaised = false;

    // Bump this whenever any C# in this file changes. A PowerShell session
    // keeps compiled types until it exits, so re-loading an edited kit into
    // an old session would silently run the OLD C# - the check after the
    // type definitions catches that. That check compares against this
    // number too; bump both together.
    public const int TypesVersion = 3;

    // Locked: Register-/Unregister-PkCancellationSource are callable from
    // worker runspaces, and List<T> is not safe for concurrent writers.
    private static readonly List<CancellationTokenSource> _sources = new List<CancellationTokenSource>();
    private static readonly object _sourcesLock = new object();

    public static void AddSource(CancellationTokenSource cts) { lock (_sourcesLock) { _sources.Add(cts); } }
    public static bool RemoveSource(CancellationTokenSource cts) { lock (_sourcesLock) { return _sources.Remove(cts); } }
    public static CancellationTokenSource[] SnapshotSources() { lock (_sourcesLock) { return _sources.ToArray(); } }
    public static int SourceCount { get { lock (_sourcesLock) { return _sources.Count; } } }
}
'@ -Language CSharp
}

if (-not ([System.Management.Automation.PSTypeName]'PkConsoleQuickEdit').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Console QuickEdit mode freezes the whole process while the user has text
// selected. Invoke-PkRun turns it off for the length of a run.
public static class PkConsoleQuickEdit
{
    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_EXTENDED_FLAGS  = 0x0080;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    // 1 = on, 0 = off, -1 = can't tell (no real console).
    public static int GetEnabled()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return -1; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return -1; }
        return (mode & ENABLE_QUICK_EDIT_MODE) != 0 ? 1 : 0;
    }

    public static bool SetEnabled(bool enabled)
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return false; }
        uint mode;
        if (!GetConsoleMode(handle, out mode)) { return false; }
        if (enabled) { mode |= ENABLE_QUICK_EDIT_MODE; } else { mode &= ~ENABLE_QUICK_EDIT_MODE; }
        mode |= ENABLE_EXTENDED_FLAGS;
        return SetConsoleMode(handle, mode);
    }
}
'@ -Language CSharp
}

if (-not ([System.Management.Automation.PSTypeName]'PkChildProcessJob').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// A Windows Job Object with KILL_ON_JOB_CLOSE: every child process assigned
// to it dies when this process exits for ANY reason, force-kill included.
public static class PkChildProcessJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // Deliberately never closed: the OS closes it when this process exits,
    // and that close is what kills the children. Closing it early would
    // kill running work.
    private static IntPtr _job = IntPtr.Zero;
    private static readonly object _lock = new object();

    public static bool IsInitialized { get { return _job != IntPtr.Zero; } }
    public static int LastError { get; private set; }

    public static bool Initialize()
    {
        lock (_lock)
        {
            if (_job != IntPtr.Zero) { return true; }
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return false; }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    LastError = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    return false;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
            _job = job;
            return true;
        }
    }

    // Never throws - a failed assignment only loses the force-kill cleanup
    // for that one process, it must not fail the work itself.
    public static bool Assign(System.Diagnostics.Process process)
    {
        if (_job == IntPtr.Zero || process == null) { return false; }
        try
        {
            if (AssignProcessToJobObject(_job, process.Handle)) { return true; }
            LastError = Marshal.GetLastWin32Error();
            return false;
        }
        catch { return false; }
    }
}
'@ -Language CSharp
}

# A session that loaded an earlier copy of this file still has that copy's
# compiled types, and they can't be replaced. Say so, instead of failing
# later with a missing-method error somewhere unrelated. Keep this number
# in sync with [PkState]::TypesVersion above.
if ((& { try { [PkState]::TypesVersion } catch { 0 } }) -ne 3) {
    throw "ParallelKit: this PowerShell session already loaded an older version of the kit, and its compiled parts can't be swapped out. Close this window and start a new one."
}

# How kit functions tell a worker runspace from the main one: in a worker
# these two globals are set by Invoke-PkRunspaceJobs; everywhere else they
# are null. Defined here so reading them is legal under Set-StrictMode.
if (-not (Test-Path -LiteralPath 'Variable:\global:PkWorkerQueue')) { $global:PkWorkerQueue = $null }
if (-not (Test-Path -LiteralPath 'Variable:\global:PkCancelToken')) { $global:PkCancelToken = $null }

# ==============================================================================
#  Messages
# ==============================================================================

function Set-PkMessageHandler {
    # $Handler receives ($Message, $Level); Level is Info, Warn or Error.
    # It always runs on the main thread. Pass $null to restore the default.
    param([scriptblock]$Handler)
    [PkState]::MessageHandler = $Handler
}

function Invoke-PkMessageHandler {
    # Main thread only.
    param([string]$Message, [string]$Level = 'Info')
    $handler = [PkState]::MessageHandler
    if ($null -ne $handler) {
        try {
            $null = & $handler $Message $Level   # a handler's stray output must not become our caller's output
            return
        } catch {
            # A handler that fails (a locked log file, say) must not take
            # the run down with it. Fall back to the console for this one
            # message and say why.
            Write-Host ("[ParallelKit] message handler failed (" + $_ + ") - showing the message here instead:") -ForegroundColor Yellow
        }
    }
    $color = switch ($Level) { 'Error' { 'Red' } 'Warn' { 'Yellow' } default { $null } }
    if ($color) { Write-Host $Message -ForegroundColor $color } else { Write-Host $Message }
}

function Write-PkMessage {
    # Safe to call from anywhere. In a worker runspace the message is queued
    # and the main thread delivers it; on the main thread it goes straight to
    # the message handler.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [string]$Level = 'Info'
    )
    if ($null -ne $global:PkWorkerQueue) {
        $global:PkWorkerQueue.Enqueue(@{ Message = $Message; Level = $Level })
        return
    }
    Invoke-PkMessageHandler -Message $Message -Level $Level
}

function Receive-PkWorkerMessages {
    # Main thread only: deliver everything workers have queued so far.
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue)
    if ($null -eq $Queue) { return }
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        Invoke-PkMessageHandler -Message $item.Message -Level $item.Level
    }
}

# ==============================================================================
#  Abort handling
# ==============================================================================

function Register-PkAbortHandler {
    [PkConsoleCtrl]::Register()
    if (-not [PkConsoleCtrl]::LastRegisterSucceeded) {
        Invoke-PkMessageHandler -Level Warn -Message "[WARNING] Could not register the Ctrl+C/window-close handler - aborting a run may not drain gracefully (Ctrl+C will use the OS default action instead)."
    }
    return [PkConsoleCtrl]::LastRegisterSucceeded
}

function Initialize-PkChildProcessJob {
    if ([PkChildProcessJob]::Initialize()) { return $true }
    Invoke-PkMessageHandler -Level Warn -Message ("[WARNING] Could not set up child-process cleanup (Win32 error " + [PkChildProcessJob]::LastError + ") - if this window is force-closed mid-run, a running child process may be left behind and need ending in Task Manager.")
    return $false
}

function Initialize-PkThreadPool {
    # Every redirected child process holds two thread-pool threads for its
    # async stdout/stderr reads. The pool grows slowly past its minimum, so
    # a burst of processes can leave reads waiting long enough to look like
    # a hung process. Raise the minimum up front.
    param([int]$MaxConcurrentProcesses = 0)
    $clampedProcs = [Math]::Min([Math]::Max($MaxConcurrentProcesses, 0), 16000)
    $minimumWorkerThreads = [Math]::Max(128, (2 * $clampedProcs) + 32)
    $worker = 0; $io = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
    [PkState]::ThreadPoolRaised = $true
    if ($worker -ge $minimumWorkerThreads) { return $true }
    return [System.Threading.ThreadPool]::SetMinThreads($minimumWorkerThreads, $io)
}

function Initialize-ParallelKit {
    # One-call setup. Safe to call more than once.
    param([int]$MaxConcurrentProcesses = 0)
    $handlerOk = Register-PkAbortHandler
    $jobOk     = Initialize-PkChildProcessJob
    $poolOk    = Initialize-PkThreadPool -MaxConcurrentProcesses $MaxConcurrentProcesses
    return @{ AbortHandler = $handlerOk; ChildProcessJob = $jobOk; ThreadPool = $poolOk }
}

function Set-PkRunActive {
    param([Parameter(Mandatory)][bool]$Active)
    [PkConsoleCtrl]::RunActive = $Active
}

function Set-PkConsoleQuickEdit {
    param([Parameter(Mandatory)][bool]$Enabled)
    return [PkConsoleQuickEdit]::SetEnabled($Enabled)
}

function Register-PkCancellationSource {
    # Every registered source is cancelled the moment an abort is detected.
    # An abort stays in force until Reset-PkAbortState (Invoke-PkRun does
    # that at the start of each run), so a source registered while one is
    # still in force is cancelled on the spot - otherwise a later run would
    # start normally while its workers, seeing the old flag, quietly did nothing.
    param([Parameter(Mandatory)][System.Threading.CancellationTokenSource]$Cts)
    [PkState]::AddSource($Cts)
    if ([PkState]::AbortLatched) {
        try { $Cts.Cancel() } catch { }   # an already-disposed source has nothing left to cancel
    }
}

function Unregister-PkCancellationSource {
    param([Parameter(Mandatory)][System.Threading.CancellationTokenSource]$Cts)
    $null = [PkState]::RemoveSource($Cts)
}

function Reset-PkAbortState {
    # Clears a finished abort so work can carry on. Deliberately leaves
    # RunActive alone: that belongs to Invoke-PkRun, and clearing it here
    # would disarm a run that calls this part-way through.
    [PkState]::AbortLatched = $false
    [PkState]::CloseAbort   = $false
    [PkConsoleCtrl]::AbortRequested = $false
    [PkConsoleCtrl]::IsCloseEvent   = $false
    [PkConsoleCtrl]::DrainComplete.Reset()
}

function Request-PkAbort {
    # Programmatic abort - same effect as the user pressing Ctrl+C mid-run.
    [PkConsoleCtrl]::AbortRequested = $true
}

function Test-PkAbortSignal {
    # In a worker: just reports the flag. On the main thread: the first call
    # after an abort also cancels every registered source and announces it.
    if ($null -ne $global:PkWorkerQueue) {
        return [PkConsoleCtrl]::AbortRequested
    }

    if ([PkConsoleCtrl]::AbortRequested -and -not [PkState]::AbortLatched) {
        [PkState]::AbortLatched = $true
        [PkState]::CloseAbort   = [PkConsoleCtrl]::IsCloseEvent
        foreach ($cts in [PkState]::SnapshotSources()) {
            try { $cts.Cancel() } catch { }   # an already-disposed source has nothing left to cancel
        }
        $abortMessage = if (-not [PkState]::CloseAbort) {
            "[ABORT] Ctrl+C detected - finishing current jobs, please wait..."
        } else {
            "[ABORT] Window close detected - finishing current jobs, please wait..."
        }
        Invoke-PkMessageHandler -Message $abortMessage -Level Warn
    }
    return [PkState]::AbortLatched
}

function Test-PkCancelRequested {
    # For worker code: true once this run is being cancelled or aborted.
    if ($null -ne $global:PkCancelToken -and $global:PkCancelToken.IsCancellationRequested) { return $true }
    return [PkConsoleCtrl]::AbortRequested
}

function Get-PkAbortTriggerLabel {
    if ([PkState]::CloseAbort) { return "window close (X button)" }
    return "Ctrl+C"
}

function Complete-PkAbortDrain {
    # Releases the native handler thread. Idempotent; safe on a run that was
    # never aborted.
    try { [PkConsoleCtrl]::DrainComplete.Set() } catch { }   # nothing useful to do if the event itself is broken
}

function Test-PkOwnAbortException {
    # True when an exception is just the fallout of our own abort.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exType = $ErrorRecord.Exception.GetType().FullName
    return ((Test-PkAbortSignal) -and ($exType -like '*PipelineStoppedException*' -or $exType -like '*OperationCanceled*'))
}

function Invoke-PkRun {
    # Brackets a run: inside $ScriptBlock, Ctrl+C / closing the window asks
    # the engines to stop cleanly instead of killing the process.
    #
    # Inside the bracket Ctrl+C no longer kills anything by itself - it only
    # raises a flag. The kit's engines watch it. A long step of YOUR OWN in
    # here must check Test-PkAbortSignal now and then and stop when it turns
    # true, or Ctrl+C will appear to do nothing until that step ends.
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [bool]$DisableQuickEdit = $true,
        # Stop the PC idle-sleeping for the length of the run (the display
        # can still turn off; lid close / Start -> Sleep still work).
        [bool]$KeepAwake = $true
    )
    # Already inside a run (a helper that brackets its own work, called
    # from a bracketed caller): just run it. Re-arming here would wipe the
    # outer run's abort state, and disarming on the way out would leave the
    # rest of the outer run unprotected.
    if ([PkConsoleCtrl]::RunActive) {
        & $ScriptBlock
        return
    }
    if (-not [PkConsoleCtrl]::LastRegisterSucceeded) { $null = Register-PkAbortHandler }
    if (-not [PkChildProcessJob]::IsInitialized)     { $null = Initialize-PkChildProcessJob }
    Reset-PkAbortState
    [PkConsoleCtrl]::RunActive = $true
    # Only turn QuickEdit back on afterwards if it was on to begin with.
    $quickEditWasOn = ([PkConsoleQuickEdit]::GetEnabled() -eq 1)
    if ($DisableQuickEdit -and $quickEditWasOn) { $null = [PkConsoleQuickEdit]::SetEnabled($false) }
    if ($KeepAwake) { $null = [PkSleepBlock]::Block() }
    try {
        & $ScriptBlock
    } finally {
        if ($KeepAwake) { $null = [PkSleepBlock]::Unblock() }
        if ($DisableQuickEdit -and $quickEditWasOn) { $null = [PkConsoleQuickEdit]::SetEnabled($true) }
        [PkConsoleCtrl]::RunActive = $false
        Complete-PkAbortDrain
    }
}

# ==============================================================================
#  External processes (all raw .NET - safe inside workers)
# ==============================================================================

function ConvertTo-PkArgumentString {
    # Joins arguments into one command line, quoting each so a program sees
    # exactly that list: an argument with a space, tab, newline or quote is
    # wrapped in quotes, its quotes become \", and backslashes are doubled
    # where they come before a quote. These are the C runtime's rules, which
    # most Windows programs use (cmd.exe's own parsing is different).
    # .NET Framework's ProcessStartInfo has no ArgumentList, hence this.
    #   ConvertTo-PkArgumentString @($in, '-o', $out)  ->  "C:\My Files\a.png" -o C:\out\a.jxl
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) { $arg = '' }
        if ($arg.Length -gt 0 -and $arg.IndexOfAny([char[]]@(' ', "`t", "`n", "`v", '"')) -lt 0) {
            $parts.Add($arg)
            continue
        }
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.Append('"')
        $backslashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                # Each backslash before a quote is doubled, then the quote escaped.
                $null = $sb.Append('\', 2 * $backslashes + 1)
                $null = $sb.Append('"')
            } else {
                if ($backslashes -gt 0) { $null = $sb.Append('\', $backslashes) }
                $null = $sb.Append($ch)
            }
            $backslashes = 0
        }
        # Trailing backslashes are doubled so they don't escape the closing quote.
        if ($backslashes -gt 0) { $null = $sb.Append('\', 2 * $backslashes) }
        $null = $sb.Append('"')
        $parts.Add($sb.ToString())
    }
    return ($parts -join ' ')
}

function Start-PkProcess {
    # Starts a hidden child process with stdout/stderr redirected and being
    # read asynchronously (so a chatty process can't block on a full pipe).
    # Returns @{ Proc; StdoutTask; StderrTask; Stopwatch }.
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = ""
    )
    # Self-starting: a caller who never ran Initialize-ParallelKit still
    # gets children that die with the script, and output reads that
    # aren't starved of threads. Both are cheap no-ops once done.
    if (-not [PkChildProcessJob]::IsInitialized) { $null = [PkChildProcessJob]::Initialize() }
    if (-not [PkState]::ThreadPoolRaised)        { $null = Initialize-PkThreadPool }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    # In a try/catch on purpose: a bare .NET call that throws does not
    # reliably stop a PowerShell script, and a $null process left behind
    # would be polled forever.
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw ("Start-PkProcess: could not start '" + $FilePath + "': " + $_)
    }
    $null = [PkChildProcessJob]::Assign($proc)
    return @{
        Proc       = $proc
        StdoutTask = $proc.StandardOutput.ReadToEndAsync()
        StderrTask = $proc.StandardError.ReadToEndAsync()
        Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Stop-PkProcessTree {
    # Kills a process and every process it started (taskkill /T /F), so
    # none of them is left holding its output open. Falls back to killing
    # just the process. Returns $true if this call killed it, $false if it
    # had already exited on its own.
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return $false }
    $killed = $false
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\taskkill.exe'), ('/T /F /PID ' + $Process.Id))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $taskkill = [System.Diagnostics.Process]::Start($psi)
        try {
            if ($taskkill.WaitForExit(10000)) { $killed = ($taskkill.ExitCode -eq 0) }
        } finally { $taskkill.Dispose() }
    } catch { }  # taskkill missing or blocked: the fallback below still kills the process itself
    if (-not $killed -and -not $Process.HasExited) {
        try { $Process.Kill(); $killed = $true } catch { }  # it exited between the check and the kill
    }
    if ($killed) { $null = $Process.WaitForExit(5000) }
    return $killed
}

function Wait-PkProcess {
    # Waits on the raw process handle. Returns $true if it exited in time.
    # (Process.WaitForExit(int) also waits on the redirected streams and can
    # hang past its own timeout - this can't.)
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )
    $waitHandle = [System.Threading.ManualResetEvent]::new($false)
    $origHandle = $waitHandle.SafeWaitHandle
    $waitHandle.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new($Process.Handle, $false)
    try {
        return $waitHandle.WaitOne($TimeoutMs)
    } finally {
        $waitHandle.SafeWaitHandle = $origHandle
        $waitHandle.Dispose()
    }
}

function Complete-PkProcess {
    # Call once the process has exited. Returns
    # @{ ExitCode; Stdout; Stderr; StreamTimedOut; StreamError }. A process that exited
    # can still have an open pipe (a grandchild inherited it), so the stream
    # read is bounded too.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Job,
        [int]$StreamTimeoutMs = 15000,
        [bool]$Dispose = $false
    )
    $result = @{ ExitCode = $null; Stdout = $null; Stderr = $null; StreamTimedOut = $false; StreamError = $null }
    # A job started by a custom starter may have no read tasks, and a read
    # can fail. Neither is worth an exception here - this runs inside
    # JobFinalize, where a throw stops the whole dispatcher.
    $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    if ($null -ne $Job['StdoutTask']) { $tasks.Add($Job['StdoutTask']) }
    if ($null -ne $Job['StderrTask']) { $tasks.Add($Job['StderrTask']) }
    if ($tasks.Count -gt 0) {
        try {
            if (-not [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $StreamTimeoutMs)) { $result.StreamTimedOut = $true }
        } catch {
            $result.StreamError = [string]$_.Exception.Message
        }
    }
    $ranToCompletion = [System.Threading.Tasks.TaskStatus]::RanToCompletion
    if ($null -ne $Job['StdoutTask'] -and $Job['StdoutTask'].Status -eq $ranToCompletion) { $result.Stdout = $Job['StdoutTask'].Result }
    if ($null -ne $Job['StderrTask'] -and $Job['StderrTask'].Status -eq $ranToCompletion) { $result.Stderr = $Job['StderrTask'].Result }
    $result.ExitCode = $Job['Proc'].ExitCode
    if ($Dispose) { $Job['Proc'].Dispose() }
    return $result
}

function Invoke-PkProcessWithTimeout {
    # Run one process to completion, synchronously, with a hard time limit.
    # Returns @{ ExitCode; Stdout; Stderr; StreamTimedOut; StreamError };
    # throws if the process had to be killed - because it overran, or
    # because the run was aborted/cancelled while it was going.
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$Arguments = "",
        [int]$TimeoutMs = 60000,
        [int]$StreamTimeoutMs = 15000,
        [string]$WorkingDirectory = "",
        # For a program that has to run BECAUSE of an abort (cleanup, a
        # restore step): keep going even though the run is being aborted.
        [switch]$IgnoreAbort
    )
    $job = Start-PkProcess -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    try {
        # Wait in short slices so Ctrl+C (or the run's cancel token) is
        # noticed within a moment, not after the whole time limit.
        $waited  = [System.Diagnostics.Stopwatch]::StartNew()
        $exited  = $false
        $stopWhy = $null
        while (-not $exited) {
            $remainingMs = $TimeoutMs - [int]$waited.ElapsedMilliseconds
            if ($remainingMs -le 0) { $stopWhy = ("did not exit within " + $TimeoutMs + "ms"); break }
            $exited = Wait-PkProcess -Process $job['Proc'] -TimeoutMs ([Math]::Min(200, $remainingMs))
            if (-not $exited -and -not $IgnoreAbort -and ((Test-PkAbortSignal) -or (Test-PkCancelRequested))) { $stopWhy = "was stopped because the run is being aborted"; break }
        }
        if (-not $exited) {
            try { $job['Proc'].Kill() } catch { }   # already-exited race - the throw below still reports why
            # Let the two output reads finish (the kill closes their pipes)
            # before the process is disposed under them. Bounded, and any
            # read error is irrelevant - the stop reason is what gets reported.
            try { $null = [System.Threading.Tasks.Task]::WaitAll(@($job['StdoutTask'], $job['StderrTask']), 500) } catch { }
            throw ("'" + $FilePath + "' " + $stopWhy + " - killed")
        }
        return Complete-PkProcess -Job $job -StreamTimeoutMs $StreamTimeoutMs
    } finally {
        $job['Proc'].Dispose()
    }
}

# ==============================================================================
#  Process dispatch - run many external processes, a bounded number at a time
# ==============================================================================

function Invoke-PkProcessDispatch {
    # Work arrives as GROUPS (a folder, a batch, anything). For each group
    # $JobBuilder returns its jobs; jobs run up to $MaxConcurrent at once;
    # $GroupCompleteCallback fires when a group's last job finishes.
    #
    #   GroupProvider          { }                  -> next group object, or $null when done
    #   JobBuilder             { param($group) }    -> hashtable job(s), or @() for none
    #   JobStarter             { param($job) }      -> the job, with .Proc set (default: Start-PkProcess
    #                                                  on $job['FilePath'] / $job['Arguments'] / $job['WorkingDirectory'])
    #   JobPollCompleted       { param($job) }      -> $true once finished (default: $job['Proc'].HasExited)
    #   JobFinalize            { param($job, $pendingQueue) } -> collect the result. To retry or add
    #                                                  follow-up work, enqueue new job hashtable(s) onto
    #                                                  $pendingQueue; they join the same group
    #   JobAbortCleanup        { param($job) }      -> remove partial output of a killed/never-started job
    #   GroupCompleteCallback  { param($group) }
    #   GroupReleaseCheck      { param($group) }    -> $true to release a ZERO-job group's queue-ahead slot
    #
    # The dispatcher keeps its own state ON each job hashtable. These names
    # are its own - don't use them for anything else in your jobs:
    #   GroupKey, SlotReleased          internal bookkeeping
    #   Proc, StdoutTask, StderrTask, Stopwatch   the running process (set by the starter)
    # It also sets .Group to the job's group object, unless your job already
    # has a Group field of its own.
    # $MaxConcurrent is an int, or a SemaphoreSlim shared between several
    # dispatchers that must stay under one combined limit.
    # Returns @{ GroupResults; Aborted; ForceKilledCount; JobStarterFailedCount }.
    # Anything your callbacks output is discarded, except where a return value is listed above.
    param(
        [Parameter(Mandatory)]
        [scriptblock]$GroupProvider,
        [Parameter(Mandatory)]
        [scriptblock]$JobBuilder,
        [scriptblock]$JobStarter = $null,
        [scriptblock]$JobPollCompleted = $null,
        [Parameter(Mandatory)]
        [scriptblock]$JobFinalize,
        [scriptblock]$JobAbortCleanup = $null,
        [scriptblock]$GroupCompleteCallback = $null,
        [Parameter(Mandatory)]
        $MaxConcurrent,
        [scriptblock]$AbortPollCallback = $null,
        [System.Threading.CancellationToken]$CancelToken,
        [int]$AbortTimeoutSeconds = 60,
        [int]$MaxQueueAhead = 3,
        [scriptblock]$GroupReleaseCheck = $null
    )

    # 0 or less would never start a job (or pull a group) and spin forever.
    if ($MaxConcurrent -isnot [System.Threading.SemaphoreSlim]) {
        $maxConcurrentInt = 0
        if (-not [int]::TryParse([string]$MaxConcurrent, [ref]$maxConcurrentInt) -or $maxConcurrentInt -lt 1) {
            throw ("Invoke-PkProcessDispatch: -MaxConcurrent must be a whole number of at least 1, or a SemaphoreSlim (got '" + $MaxConcurrent + "').")
        }
        $MaxConcurrent = $maxConcurrentInt
    }
    if ($MaxQueueAhead -lt 1) { throw "Invoke-PkProcessDispatch: -MaxQueueAhead must be at least 1." }

    # Two pool threads per running process for its output reads - make sure
    # they exist up front. For a shared budget, the slots free right now
    # are the best available measure of its size.
    $poolSizeHint = 0
    if ($MaxConcurrent -is [int]) { $poolSizeHint = $MaxConcurrent }
    elseif ($MaxConcurrent -is [System.Threading.SemaphoreSlim]) { $poolSizeHint = $MaxConcurrent.CurrentCount }
    $null = Initialize-PkThreadPool -MaxConcurrentProcesses $poolSizeHint

    if ($null -eq $JobStarter) {
        $JobStarter = {
            param($job)
            $started = Start-PkProcess -FilePath $job['FilePath'] -Arguments ([string]$job['Arguments']) -WorkingDirectory ([string]$job['WorkingDirectory'])
            $job['Proc'] = $started.Proc; $job['StdoutTask'] = $started.StdoutTask; $job['StderrTask'] = $started.StderrTask
            $job['Stopwatch'] = $started.Stopwatch
            return $job
        }
    }
    # The default poll reads $job['Proc'], so a started job must have one.
    $requireProc = ($null -eq $JobPollCompleted)
    if ($null -eq $JobPollCompleted)      { $JobPollCompleted      = { param($job) return $job['Proc'].HasExited } }
    if ($null -eq $JobAbortCleanup)       { $JobAbortCleanup       = { param($job) } }
    if ($null -eq $GroupCompleteCallback) { $GroupCompleteCallback = { param($group) } }

    # Token: the caller's; else (in a worker) the run's own; else a fresh one
    # registered so an abort cancels it.
    $ownCts = $null
    if (-not $PSBoundParameters.ContainsKey('CancelToken')) {
        if ($null -ne $global:PkCancelToken) {
            $CancelToken = $global:PkCancelToken
        } else {
            $ownCts = [System.Threading.CancellationTokenSource]::new()
            Register-PkCancellationSource -Cts $ownCts
            $CancelToken = $ownCts.Token
        }
    } else {
        # The caller's own token: nothing would cancel it on Ctrl+C. Run on
        # a linked source that an abort DOES cancel (and that still follows
        # the caller's token). In a worker it also follows the run's token,
        # so the run being cancelled for any reason stops this dispatcher.
        $linkTokens = [System.Collections.Generic.List[System.Threading.CancellationToken]]::new()
        $linkTokens.Add($CancelToken)
        if ($null -ne $global:PkCancelToken) { $linkTokens.Add($global:PkCancelToken) }
        $ownCts = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($linkTokens.ToArray())
        Register-PkCancellationSource -Cts $ownCts
        $CancelToken = $ownCts.Token
    }

    try {
        return Invoke-PkProcessDispatchCore -GroupProvider $GroupProvider -JobBuilder $JobBuilder -JobStarter $JobStarter `
            -JobPollCompleted $JobPollCompleted -JobFinalize $JobFinalize -JobAbortCleanup $JobAbortCleanup `
            -GroupCompleteCallback $GroupCompleteCallback -MaxConcurrent $MaxConcurrent -AbortPollCallback $AbortPollCallback `
            -CancelToken $CancelToken -AbortTimeoutSeconds $AbortTimeoutSeconds -MaxQueueAhead $MaxQueueAhead `
            -GroupReleaseCheck $GroupReleaseCheck -RequireProc $requireProc
    } finally {
        if ($null -ne $ownCts) {
            Unregister-PkCancellationSource -Cts $ownCts
            $ownCts.Dispose()
        }
    }
}

function Invoke-PkProcessDispatchCore {
    # The dispatch loop itself. Call Invoke-PkProcessDispatch, not this.
    param(
        [scriptblock]$GroupProvider,
        [scriptblock]$JobBuilder,
        [scriptblock]$JobStarter,
        [scriptblock]$JobPollCompleted,
        [scriptblock]$JobFinalize,
        [scriptblock]$JobAbortCleanup,
        [scriptblock]$GroupCompleteCallback,
        $MaxConcurrent,
        [scriptblock]$AbortPollCallback,
        [System.Threading.CancellationToken]$CancelToken,
        [int]$AbortTimeoutSeconds,
        [int]$MaxQueueAhead,
        [scriptblock]$GroupReleaseCheck,
        [bool]$RequireProc = $false
    )

    $isSharedBudget = ($MaxConcurrent -is [System.Threading.SemaphoreSlim])

    $groupStates      = [System.Collections.Generic.Dictionary[object,hashtable]]::new()
    $groupResults     = [System.Collections.Generic.List[hashtable]]::new()
    $activeGroupCount = 0
    $providerExhausted = $false
    $heldGroups       = [System.Collections.Generic.List[object]]::new()

    $pending = [System.Collections.Generic.Queue[hashtable]]::new()
    $running = [System.Collections.Generic.List[hashtable]]::new()

    $dispatchResult = @{
        GroupResults          = $groupResults
        Aborted               = $false
        ForceKilledCount      = 0
        JobStarterFailedCount = 0
    }

    try {
    while ((-not $CancelToken.IsCancellationRequested) -and `
           (-not $providerExhausted -or $activeGroupCount -gt 0 -or $pending.Count -gt 0 -or $running.Count -gt 0)) {

        for ($h = $heldGroups.Count - 1; $h -ge 0; $h--) {
            if ([bool](& $GroupReleaseCheck $heldGroups[$h])) {
                $heldGroups.RemoveAt($h)
                $activeGroupCount--
            }
        }

        while ((-not $providerExhausted) -and $activeGroupCount -lt $MaxQueueAhead -and (-not $CancelToken.IsCancellationRequested)) {
            $groupInfo = & $GroupProvider
            if ($null -eq $groupInfo) { $providerExhausted = $true; break }
            # A fresh object per group, NOT the group value itself: two
            # groups that compare equal (the same folder name, say) must not
            # share one job count. Jobs carry this key as .GroupKey and the
            # group value itself as .Group.
            $groupKey = [object]::new()
            $rawJobs = & $JobBuilder $groupInfo
            # Assigned inside each branch, NOT `$jobs = if (...) {...} else {...}`:
            # captured through an if/else, a single hashtable gets
            # enumerated into its key/value pairs.
            if ($null -eq $rawJobs) { $rawJobList = @() } else { $rawJobList = @($rawJobs) }
            # Keep only real job hashtables: a builder that lets a stray
            # value escape (a HashSet.Add's True, say) must not crash the run.
            $jobs = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($rawJob in $rawJobList) { if ($rawJob -is [hashtable]) { $jobs.Add($rawJob) } }
            if ($jobs.Count -ne $rawJobList.Count) {
                Write-PkMessage ("ProcessDispatch: -JobBuilder returned " + ($rawJobList.Count - $jobs.Count) + " value(s) that are not job hashtables - ignored. Each job must be a hashtable.") -Level Warn
            }
            foreach ($j in $jobs) {
                $j['GroupKey'] = $groupKey
                if (-not $j.ContainsKey('Group')) { $j['Group'] = $groupInfo }   # leave a job's own 'Group' field alone
                $pending.Enqueue($j)
            }
            $state = @{ GroupInfo = $groupInfo; Outstanding = $jobs.Count; Completed = $false }
            $groupStates[$groupKey] = $state
            $activeGroupCount++
            if ($state.Outstanding -le 0) {
                $null = & $GroupCompleteCallback $groupInfo
                $state.Completed = $true
                if ($null -ne $GroupReleaseCheck) { $heldGroups.Add($groupInfo) } else { $activeGroupCount-- }
                $groupResults.Add(@{ GroupInfo = $groupInfo; Completed = $true; Aborted = $false })
            }
        }

        # Main thread: this is what notices an abort and cancels the token.
        # Worker: just reads the flag; the main thread cancels the token.
        $null = Test-PkAbortSignal
        if ($AbortPollCallback) { $null = & $AbortPollCallback @($running) }

        while ($pending.Count -gt 0 -and (-not $CancelToken.IsCancellationRequested) -and `
               $(if ($isSharedBudget) { $MaxConcurrent.Wait(0) } else { $running.Count -lt $MaxConcurrent })) {
            $job = $pending.Dequeue()
            try {
                # Don't trust the starter's output shape: a starter that
                # forgets to return the job (or leaks other output) would
                # leave something un-pollable in $running and spin forever.
                # The running job is always the caller's own job object, so
                # the fields its builder set are still there at finalize
                # time. If the starter output a DIFFERENT hashtable (a bare
                # `Start-PkProcess ...` outputs its start result), fold that
                # one's fields into the job rather than swapping the job out.
                # A job object that has been round once already (JobFinalize
                # put the SAME object back on the queue) still carries its
                # old, disposed process - clear that before it starts again.
                if ($job['SlotReleased']) {
                    $job['Proc'] = $null; $job['StdoutTask'] = $null; $job['StderrTask'] = $null; $job['Stopwatch'] = $null
                }
                $job['SlotReleased'] = $false
                $startedRaw = & $JobStarter $job
                foreach ($item in @($startedRaw)) {
                    if ($item -isnot [hashtable] -or [object]::ReferenceEquals($item, $job)) { continue }
                    foreach ($itemKey in @($item.Keys)) {
                        if ($null -eq $job[$itemKey]) { $job[$itemKey] = $item[$itemKey] }
                    }
                }
                if ($RequireProc -and $null -eq $job['Proc']) {
                    throw "JobStarter did not set the job's .Proc (set .Proc on the job and return it, or supply -JobPollCompleted)."
                }
                $running.Add($job)
            } catch {
                # Release BEFORE reporting: if reporting throws, the slot
                # would otherwise leak (this job never reached $running, so
                # the outer cleanup can't find it).
                if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                Write-PkMessage ("ProcessDispatch: JobStarter failed to start a job: " + $_) -Level Error
                $dispatchResult.JobStarterFailedCount++
                $key = $job['GroupKey']
                if ($groupStates.ContainsKey($key)) {
                    $state = $groupStates[$key]
                    $state.Outstanding--
                    if ($state.Outstanding -le 0 -and -not $state.Completed) {
                        $null = & $GroupCompleteCallback $state.GroupInfo
                        $state.Completed = $true
                        $activeGroupCount--
                        $groupResults.Add(@{ GroupInfo = $state.GroupInfo; Completed = $true; Aborted = $false })
                    }
                } else {
                    Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (JobStarter failure path). This should be unreachable; the dispatch loop may now hang.") -Level Error
                }
            }
        }

        # ---- BLOCK: main dispatch loop's poll pass ----
        # Same poll/finalize/completion sequence as the graceful-wait loop
        # and the mandatory final pass below - keep all three in sync.
        $stillRunning = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($job in $running) {
            if (& $JobPollCompleted $job) {
                $pendingBefore = $pending.Count
                $null = & $JobFinalize $job $pending
                try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }   # a failed Dispose can't affect the result already taken
                if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                $job['SlotReleased'] = $true
                # Whatever JobFinalize queued (a retry, follow-up steps) is counted
                # into its group HERE, by looking at the queue - not by trusting a
                # returned flag. A flag with nothing queued would hang the group
                # forever; two follow-ups would let it finish early.
                # Only when the queue actually grew - walking it on every finished
                # job would cost a full pass over a large batch each time.
                if ($pending.Count -gt $pendingBefore) {
                    $queuedIndex = 0
                    foreach ($queued in $pending) {
                        if ($queuedIndex -ge $pendingBefore) {
                            if ($null -eq $queued['GroupKey']) { $queued['GroupKey'] = $job['GroupKey']; if (-not $queued.ContainsKey('Group')) { $queued['Group'] = $job['Group'] } }
                            if ($groupStates.ContainsKey($queued['GroupKey'])) { $groupStates[$queued['GroupKey']].Outstanding++ }
                        }
                        $queuedIndex++
                    }
                }
                if ($null -ne $job['GroupKey']) {
                    $key = $job['GroupKey']
                    if ($groupStates.ContainsKey($key)) {
                        $state = $groupStates[$key]
                        $state.Outstanding--
                        if ($state.Outstanding -le 0 -and -not $state.Completed) {
                            $null = & $GroupCompleteCallback $state.GroupInfo
                            $state.Completed = $true
                            $activeGroupCount--
                            $groupResults.Add(@{ GroupInfo = $state.GroupInfo; Completed = $true; Aborted = $false })
                        }
                    } else {
                        Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (main poll pass). This should be unreachable; the dispatch loop may now hang.") -Level Error
                    }
                }
            } else {
                $stillRunning.Add($job)
            }
        }
        $running = $stillRunning

        [System.Threading.Thread]::Sleep(50)
    }
    } catch {
        # Best-effort teardown on the way out; the original error is rethrown.
        foreach ($job in $running) {
            try { if ($job['Proc'] -and -not $job['Proc'].HasExited) { $job['Proc'].Kill() } } catch { }
            try { if ($job['Proc']) { $null = $job['Proc'].WaitForExit(5000) } } catch { }
            if (-not $job['SlotReleased']) {
                try { $null = & $JobAbortCleanup $job } catch { }
                if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
            }
            try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }
        }
        throw
    }

    if ($CancelToken.IsCancellationRequested -and $running.Count -gt 0) {
        try {
            $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
            while ($running.Count -gt 0 -and -not [PkConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $AbortTimeoutSeconds) {
                # ---- BLOCK: graceful-wait loop ---- (keep in sync with the
                # main poll pass above and the final pass below)
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $pendingBefore = $pending.Count
                        $null = & $JobFinalize $job $pending
                        try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }
                        if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                        $job['SlotReleased'] = $true
                        # Whatever JobFinalize queued (a retry, follow-up steps) is counted
                        # into its group HERE, by looking at the queue - not by trusting a
                        # returned flag. A flag with nothing queued would hang the group
                        # forever; two follow-ups would let it finish early.
                        # Only when the queue actually grew - walking it on every finished
                        # job would cost a full pass over a large batch each time.
                        if ($pending.Count -gt $pendingBefore) {
                            $queuedIndex = 0
                            foreach ($queued in $pending) {
                                if ($queuedIndex -ge $pendingBefore) {
                                    if ($null -eq $queued['GroupKey']) { $queued['GroupKey'] = $job['GroupKey']; if (-not $queued.ContainsKey('Group')) { $queued['Group'] = $job['Group'] } }
                                    if ($groupStates.ContainsKey($queued['GroupKey'])) { $groupStates[$queued['GroupKey']].Outstanding++ }
                                }
                                $queuedIndex++
                            }
                        }
                        if ($null -ne $job['GroupKey']) {
                            $key = $job['GroupKey']
                            if ($groupStates.ContainsKey($key)) {
                                $state = $groupStates[$key]
                                $state.Outstanding--
                                if ($state.Outstanding -le 0 -and -not $state.Completed) {
                                    $null = & $GroupCompleteCallback $state.GroupInfo
                                    $state.Completed = $true
                                    $activeGroupCount--
                                    $groupResults.Add(@{ GroupInfo = $state.GroupInfo; Completed = $true; Aborted = $false })
                                }
                            } else {
                                Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (graceful-wait loop). This should be unreachable.") -Level Error
                            }
                        }
                    } else {
                        $stillWaiting.Add($job)
                    }
                }
                $running = $stillWaiting
                if ($running.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
            }

            # ---- BLOCK: mandatory final completion-check pass ----
            # A window-close can exit the loop above before a single poll, and
            # a job can finish in the last 250ms before the deadline. One more
            # pass so a finished job is never thrown away as "force-stopped".
            # (keep in sync with the two blocks above)
            if ($running.Count -gt 0) {
                $stillWaiting = [System.Collections.Generic.List[hashtable]]::new()
                foreach ($job in $running) {
                    if (& $JobPollCompleted $job) {
                        $pendingBefore = $pending.Count
                        $null = & $JobFinalize $job $pending
                        try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }
                        if ($isSharedBudget) { $null = $MaxConcurrent.Release() }
                        $job['SlotReleased'] = $true
                        # Whatever JobFinalize queued (a retry, follow-up steps) is counted
                        # into its group HERE, by looking at the queue - not by trusting a
                        # returned flag. A flag with nothing queued would hang the group
                        # forever; two follow-ups would let it finish early.
                        # Only when the queue actually grew - walking it on every finished
                        # job would cost a full pass over a large batch each time.
                        if ($pending.Count -gt $pendingBefore) {
                            $queuedIndex = 0
                            foreach ($queued in $pending) {
                                if ($queuedIndex -ge $pendingBefore) {
                                    if ($null -eq $queued['GroupKey']) { $queued['GroupKey'] = $job['GroupKey']; if (-not $queued.ContainsKey('Group')) { $queued['Group'] = $job['Group'] } }
                                    if ($groupStates.ContainsKey($queued['GroupKey'])) { $groupStates[$queued['GroupKey']].Outstanding++ }
                                }
                                $queuedIndex++
                            }
                        }
                        if ($null -ne $job['GroupKey']) {
                            $key = $job['GroupKey']
                            if ($groupStates.ContainsKey($key)) {
                                $state = $groupStates[$key]
                                $state.Outstanding--
                                if ($state.Outstanding -le 0 -and -not $state.Completed) {
                                    $null = & $GroupCompleteCallback $state.GroupInfo
                                    $state.Completed = $true
                                    $activeGroupCount--
                                    $groupResults.Add(@{ GroupInfo = $state.GroupInfo; Completed = $true; Aborted = $false })
                                }
                            } else {
                                Write-PkMessage ("ProcessDispatch: invariant violation - job's GroupKey is not registered (final pass). This should be unreachable.") -Level Error
                            }
                        }
                    } else {
                        $stillWaiting.Add($job)
                    }
                }
                $running = $stillWaiting
            }

            if ($running.Count -gt 0) {
                $dispatchResult.ForceKilledCount = $running.Count
                Write-PkMessage ("ProcessDispatch: force-stopping " + $running.Count + " job(s) that did not finish within " + $AbortTimeoutSeconds + "s.") -Level Warn
                foreach ($job in $running) {
                    try { if ($job['Proc'] -and -not $job['Proc'].HasExited) { $job['Proc'].Kill() } } catch { }
                    try { if ($job['Proc']) { $null = $job['Proc'].WaitForExit(5000) } } catch { }
                    try { $null = & $JobAbortCleanup $job } catch { }
                    try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }
                    if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
                    $job['SlotReleased'] = $true
                }
            }
        } catch {
            foreach ($job in $running) {
                try { if ($job['Proc'] -and -not $job['Proc'].HasExited) { $job['Proc'].Kill() } } catch { }
                try { if ($job['Proc']) { $null = $job['Proc'].WaitForExit(5000) } } catch { }
                if (-not $job['SlotReleased']) {
                    try { $null = & $JobAbortCleanup $job } catch { }
                    if ($isSharedBudget) { try { $null = $MaxConcurrent.Release() } catch { } }
                }
                try { if ($job['Proc']) { $job['Proc'].Dispose() } } catch { }
            }
            throw
        }
    }

    # Jobs still pending here were never started (only reachable via
    # cancellation). Clean them up and count them off, or their group could
    # never be reported.
    if ($pending.Count -gt 0) {
        foreach ($job in $pending) {
            try { $null = & $JobAbortCleanup $job } catch { }
            $key = $job['GroupKey']
            if ($groupStates.ContainsKey($key)) { $groupStates[$key].Outstanding-- }
        }
        $pending.Clear()
    }

    $dispatchResult.Aborted = $CancelToken.IsCancellationRequested
    foreach ($state in $groupStates.Values) {
        if (-not $state.Completed) {
            # An aborted group still gets its callback - it's the only place
            # the caller can credit the jobs that DID finish before the stop.
            # Swallowed: one callback failing during teardown shouldn't cost
            # every other group its result.
            try { $null = & $GroupCompleteCallback $state.GroupInfo } catch { }
            $state.Completed = $true
            $groupResults.Add(@{ GroupInfo = $state.GroupInfo; Completed = $false; Aborted = $true })
        }
    }

    return $dispatchResult
}

function Invoke-PkProcessBatch {
    # The simple case: run a flat list of commands, $MaxConcurrent at a time.
    # Each command is @{ FilePath = ...; Arguments = ...; WorkingDirectory = ... (optional); <anything else> }.
    # $OnComplete { param($command, $result) } fires as each one finishes
    # (not for one that couldn't start or was stopped by an abort).
    # $TimeoutSeconds > 0 kills a program still running after that long; its
    # result has TimedOut = $true (0 = no limit).
    # Returns @{ Results; Aborted; ForceKilledCount }; each result is
    # @{ Command; ExitCode; Stdout; Stderr; StreamTimedOut; StreamError; StartError; Aborted; TimedOut },
    # every field always present - keep the three places that build one in sync.
    # $Commands may be $null: a foreach that matches nothing yields $null, not
    # an empty array, and an empty batch should just return no results.
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$Commands,
        [int]$MaxConcurrent = 4,
        [scriptblock]$OnComplete = $null,
        [int]$AbortTimeoutSeconds = 60,
        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -lt 0) { throw "Invoke-PkProcessBatch: -TimeoutSeconds must be 0 (no limit) or more." }

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $state   = @{ Given = $false }

    $groupProvider = {
        if ($state.Given) { return $null }
        $state.Given = $true
        return @{ Name = 'batch' }
    }.GetNewClosure()

    $jobBuilder = {
        param($group)
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($c in $Commands) {
            if ($null -eq $c) { continue }
            $jobs.Add(@{ FilePath = $c['FilePath']; Arguments = [string]$c['Arguments']; WorkingDirectory = [string]$c['WorkingDirectory']; Command = $c })
        }
        return $jobs
    }.GetNewClosure()

    $jobStarter = {
        param($job)
        try {
            $started = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments'] -WorkingDirectory $job['WorkingDirectory']
        } catch {
            $results.Add(@{ Command = $job['Command']; ExitCode = $null; Stdout = $null; Stderr = $null; StreamTimedOut = $false; StreamError = $null; StartError = [string]$_; Aborted = $false; TimedOut = $false })
            throw
        }
        $job['Proc'] = $started.Proc; $job['StdoutTask'] = $started.StdoutTask; $job['StderrTask'] = $started.StderrTask
        $job['Stopwatch'] = $started.Stopwatch; $job['TimedOut'] = $false
        return $job
    }.GetNewClosure()

    $jobFinalize = {
        param($job, $pendingQueue)
        $r = Complete-PkProcess -Job $job
        $r.Command = $job['Command']; $r.StartError = $null; $r.Aborted = $false; $r.TimedOut = [bool]$job['TimedOut']
        $results.Add($r)
        if ($null -ne $OnComplete) { $null = & $OnComplete $job['Command'] $r }
        return @{ Success = ($r.ExitCode -eq 0) }
    }.GetNewClosure()

    $jobAbortCleanup = {
        param($job)
        $results.Add(@{ Command = $job['Command']; ExitCode = $null; Stdout = $null; Stderr = $null; StreamTimedOut = $false; StreamError = $null; StartError = $null; Aborted = $true; TimedOut = $false })
    }.GetNewClosure()

    $dispatchParams = @{
        GroupProvider = $groupProvider; JobBuilder = $jobBuilder; JobStarter = $jobStarter
        JobFinalize = $jobFinalize; JobAbortCleanup = $jobAbortCleanup; MaxConcurrent = $MaxConcurrent
        AbortTimeoutSeconds = $AbortTimeoutSeconds; MaxQueueAhead = 1
    }
    if ($TimeoutSeconds -gt 0) {
        # Kill an overrunning program; the next poll sees it exited and it
        # goes through $jobFinalize like any other, flagged TimedOut.
        $dispatchParams['JobPollCompleted'] = {
            param($job)
            if (-not $job['Proc'].HasExited -and $job['Stopwatch'].Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                # Only flagged if this call did the killing: a program that
                # exited on its own right at the deadline didn't time out.
                if (Stop-PkProcessTree -Process $job['Proc']) { $job['TimedOut'] = $true }
            }
            return $job['Proc'].HasExited
        }.GetNewClosure()
    }
    $dispatch = Invoke-PkProcessDispatch @dispatchParams

    return @{ Results = $results; Aborted = $dispatch.Aborted; ForceKilledCount = $dispatch.ForceKilledCount }
}

# ==============================================================================
#  Runspace jobs - run PowerShell worker scripts in parallel
# ==============================================================================

function Get-PkWorkerSafeFunctionNames {
    # Kit functions every worker runspace gets automatically.
    return @('Write-PkMessage', 'Test-PkAbortSignal', 'Test-PkCancelRequested', 'Initialize-PkThreadPool', 'Stop-PkProcessTree',
             'Start-PkProcess', 'Wait-PkProcess', 'Complete-PkProcess', 'Invoke-PkProcessWithTimeout',
             'Invoke-PkProcessDispatch', 'Invoke-PkProcessDispatchCore', 'Invoke-PkProcessBatch',
             'Register-PkCancellationSource', 'Unregister-PkCancellationSource', 'ConvertTo-PkArgumentString')
}

function Receive-PkCompletedHandles {
    param(
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [scriptblock]$ErrorHandler
    )
    $stillActive = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($h in $Handles) {
        if ($h.Handle.IsCompleted) {
            $results = $null
            try {
                $results = $h.PS.EndInvoke($h.Handle)
            } catch {
                if ($null -ne $ErrorHandler) { $null = & $ErrorHandler ("Error collecting runspace result during abort drain: " + $_) }
            } finally {
                $h.PS.Dispose()
            }
            if ($null -ne $ResultHandler -and $null -ne $results) {
                foreach ($r in $results) { $null = & $ResultHandler $r }
            }
        } else {
            $stillActive.Add($h)
        }
    }
    return ,$stillActive
}

function Invoke-PkGracefulDrain {
    # After an abort: give running workers $TimeoutSeconds to finish, collect
    # what they return, force-stop the rest. Always releases the native
    # handler thread, even if something in here throws.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Handles,
        [scriptblock]$ResultHandler,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$MessageQueue,
        [int]$TimeoutSeconds = 60,
        [string]$AbortWaitMessage
    )

    if ($Handles.Count -eq 0) {
        Complete-PkAbortDrain
        return @{ ForceStoppedCount = 0 }
    }

    if (-not $PSBoundParameters.ContainsKey('AbortWaitMessage')) {
        $AbortWaitMessage = "[ABORT] Waiting for current jobs to finish (up to " + $TimeoutSeconds + "s)..."
    }

    $errorHandler  = { param($msg) Invoke-PkMessageHandler -Message $msg -Level Error }
    $localHandles  = $Handles
    $abortDeadline = [System.Diagnostics.Stopwatch]::StartNew()
    $forceStoppedCount = 0

    try {
        if ($AbortWaitMessage -ne "") { Invoke-PkMessageHandler -Message $AbortWaitMessage -Level Warn }

        while ($localHandles.Count -gt 0 -and -not [PkConsoleCtrl]::IsCloseEvent -and $abortDeadline.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $localHandles = Receive-PkCompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $errorHandler
            Receive-PkWorkerMessages -Queue $MessageQueue
            if ($localHandles.Count -gt 0) { [System.Threading.Thread]::Sleep(250) }
        }

        # One final pass before declaring anything force-stopped.
        if ($localHandles.Count -gt 0) {
            $localHandles = Receive-PkCompletedHandles -Handles $localHandles -ResultHandler $ResultHandler -ErrorHandler $errorHandler
            Receive-PkWorkerMessages -Queue $MessageQueue
        }

        if ($localHandles.Count -gt 0) {
            $forceStoppedCount = $localHandles.Count
            Invoke-PkMessageHandler -Level Error -Message ("[ABORT] Force-stopping " + $forceStoppedCount + " job(s) that did not finish within " + $TimeoutSeconds + "s.")
            foreach ($h in $localHandles) {
                # BeginStop, not Stop: Stop() blocks until the pipeline
                # actually unwinds, and a worker stuck in a .NET call never does.
                try { $null = $h.PS.BeginStop($null, $null) } catch { }
            }
        }

        Receive-PkWorkerMessages -Queue $MessageQueue
    } finally {
        Complete-PkAbortDrain
    }

    return @{ ForceStoppedCount = $forceStoppedCount }
}

function Invoke-PkRunspaceJobs {
    # Runs $WorkerScript once per job, up to $MaxParallel at a time, each in
    # its own runspace.
    #
    #   WorkerScript         a scriptblock with a param() block. Each job's
    #                        hashtable keys are passed as its parameters. If
    #                        it declares $CancelToken, it gets the run's token.
    #   JobParams            a fixed list/array of job hashtables (or just one), OR
    #   NextJobProvider      { } -> next job hashtable, or $null when done
    #                        (runs on the main thread, so it can be lazy)
    #   SharedFunctionNames  YOUR functions the worker calls - a runspace
    #                        starts empty apart from the kit's own
    #   ResultHandler        { param($result) }  main thread, once per object a worker returns
    #   PollCallback         { }                 main thread, every loop pass
    #   JobCrashedHandler    { param($errorRecord) }  main thread, when a worker throws
    #
    # Returns @{ ForceStoppedCount; CrashedCount; Aborted }.
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        $JobParams = $null,
        [scriptblock]$NextJobProvider = $null,
        [string[]]$SharedFunctionNames = @(),
        [Parameter(Mandatory)]
        [int]$MaxParallel,
        [System.Threading.CancellationTokenSource]$Cts = $null,
        [scriptblock]$ResultHandler = $null,
        [scriptblock]$PollCallback = $null,
        [scriptblock]$JobCrashedHandler = $null,
        [int]$DrainTimeoutSeconds = 60,
        [string]$AbortWaitMessage,
        # On by default; -CheckWorkerSafety:$false turns it off.
        [switch]$CheckWorkerSafety = $true
    )

    if ($null -eq $JobParams -and $null -eq $NextJobProvider) {
        throw "Invoke-PkRunspaceJobs: must supply either -JobParams or -NextJobProvider."
    }
    if ($null -ne $JobParams -and $null -ne $NextJobProvider) {
        throw "Invoke-PkRunspaceJobs: supply only one of -JobParams or -NextJobProvider, not both."
    }
    if ($MaxParallel -lt 1) { throw "Invoke-PkRunspaceJobs: -MaxParallel must be at least 1." }

    # Accept a List, an array, or a single hashtable. A job list built with
    # `foreach` collapses to ONE bare hashtable when there is only one job -
    # that must work the same as two.
    if ($null -ne $JobParams) {
        $normalizedJobs = [System.Collections.Generic.List[hashtable]]::new()
        if ($JobParams -is [hashtable]) {
            $normalizedJobs.Add($JobParams)
        } else {
            foreach ($jobEntry in $JobParams) {
                if ($jobEntry -isnot [hashtable]) {
                    throw ("Invoke-PkRunspaceJobs: -JobParams entry " + $normalizedJobs.Count + " is not a hashtable. Each job must be a hashtable of the worker's parameters.")
                }
                $normalizedJobs.Add($jobEntry)
            }
        }
        $JobParams = $normalizedJobs
    }

    $outcome = @{ ForceStoppedCount = 0; CrashedCount = 0; Aborted = $false }
    if ($null -ne $JobParams -and $JobParams.Count -eq 0) { return $outcome }

    if ($CheckWorkerSafety) {
        $safetyFindings = Test-PkWorkerSafety -WorkerScript $WorkerScript -SharedFunctionNames $SharedFunctionNames
        if ($safetyFindings.Count -gt 0) {
            $safetyLines = foreach ($f in $safetyFindings) { "  " + $f.Text }
            throw ("Invoke-PkRunspaceJobs: worker code breaks the worker-safety rules (see README.md):`r`n" + ($safetyLines -join "`r`n"))
        }
    }

    if ($null -eq $ResultHandler) { $ResultHandler = { param($r) } }

    # Which parameters the worker actually declares - passing one it doesn't
    # declare fails the whole invoke with an unhelpful binding error.
    $declaredParams = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $WorkerScript.Ast.ParamBlock) {
        foreach ($p in $WorkerScript.Ast.ParamBlock.Parameters) { $null = $declaredParams.Add($p.Name.VariablePath.UserPath) }
    }

    # A fixed list can be checked before a single worker starts.
    if ($null -ne $JobParams) {
        for ($jobIndex = 0; $jobIndex -lt $JobParams.Count; $jobIndex++) {
            if ($null -eq $JobParams[$jobIndex]) { throw ("Invoke-PkRunspaceJobs: -JobParams entry " + $jobIndex + " is null.") }
            foreach ($key in $JobParams[$jobIndex].Keys) {
                if (-not $declaredParams.Contains([string]$key)) {
                    throw ("Invoke-PkRunspaceJobs: job " + $jobIndex + " supplies '" + $key + "', but -WorkerScript's param() block doesn't declare it. Nothing was started.")
                }
            }
            if ($CheckWorkerSafety) {
                $sbKey = Get-PkScriptBlockJobKey -Job $JobParams[$jobIndex]
                if ($null -ne $sbKey) { throw ((Get-PkScriptBlockJobMessage -Job ("job " + $jobIndex) -Key $sbKey) + " Nothing was started.") }
            }
        }
    }

    $fixedListIndex = 0
    $ownCts         = $null
    $registeredCallerCts = $false
    $messageQueue   = $null
    $pool           = $null
    $handles        = [System.Collections.Generic.List[hashtable]]::new()
    $scanExhausted  = $false

    try {
        if ($null -eq $Cts) {
            $ownCts = [System.Threading.CancellationTokenSource]::new()
            Register-PkCancellationSource -Cts $ownCts
            $Cts = $ownCts
        } else {
            # The caller's own source: register it for the length of this
            # run so Ctrl+C cancels it too.
            Register-PkCancellationSource -Cts $Cts
            $registeredCallerCts = $true
        }
        $messageQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $allShared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in (Get-PkWorkerSafeFunctionNames)) { $null = $allShared.Add($n) }
        foreach ($n in $SharedFunctionNames)            { $null = $allShared.Add($n) }
        foreach ($sharedFn in $allShared) {
            try {
                $fnDef = (Get-Item ("Function:\" + $sharedFn) -ErrorAction Stop).Definition
            } catch {
                throw ("Invoke-PkRunspaceJobs: -SharedFunctionNames entry '" + $sharedFn + "' does not resolve to a defined function - check for a typo, or that the file defining it was dot-sourced before this call. Original error: " + $_)
            }
            $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($sharedFn, $fnDef))
        }
        # Global variables in every worker runspace: how kit functions know
        # they're in a worker, and where they find the run's token.
        $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('PkWorkerQueue', $messageQueue, 'ParallelKit worker message queue'))
        $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('PkCancelToken', $Cts.Token, 'ParallelKit run cancellation token'))

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxParallel, $iss, $Host)
        $pool.Open()

        while ((-not $scanExhausted -or $handles.Count -gt 0) -and -not $Cts.Token.IsCancellationRequested) {

            while (-not $scanExhausted -and $handles.Count -lt $MaxParallel -and -not $Cts.Token.IsCancellationRequested) {
                if ($null -ne $JobParams) {
                    if ($fixedListIndex -lt $JobParams.Count) {
                        $nextJob = $JobParams[$fixedListIndex]
                        $fixedListIndex++
                    } else {
                        $nextJob = $null
                    }
                } else {
                    # Same as the dispatcher's builder: take the job
                    # hashtable, ignore anything else the provider let out.
                    $nextRaw = & $NextJobProvider
                    $nextJob = $null
                    $strayCount = 0
                    foreach ($rawItem in @($nextRaw)) {
                        if ($rawItem -is [hashtable]) { $nextJob = $rawItem } elseif ($null -ne $rawItem) { $strayCount++ }
                    }
                    if ($strayCount -gt 0) {
                        Invoke-PkMessageHandler -Level Warn -Message ("Invoke-PkRunspaceJobs: -NextJobProvider returned " + $strayCount + " value(s) that are not a job hashtable - ignored.")
                    }
                }
                if ($null -eq $nextJob) { $scanExhausted = $true; break }

                foreach ($key in $nextJob.Keys) {
                    if (-not $declaredParams.Contains([string]$key)) {
                        throw ("Invoke-PkRunspaceJobs: a job supplies '" + $key + "', but -WorkerScript's param() block doesn't declare it.")
                    }
                }
                if ($CheckWorkerSafety -and $null -eq $JobParams) {
                    $sbKey = Get-PkScriptBlockJobKey -Job $nextJob
                    if ($null -ne $sbKey) { throw (Get-PkScriptBlockJobMessage -Job "a job from -NextJobProvider" -Key $sbKey) }
                }

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                $null = $ps.AddScript($WorkerScript)
                foreach ($key in $nextJob.Keys) { $null = $ps.AddParameter($key, $nextJob[$key]) }
                if ($declaredParams.Contains('CancelToken') -and -not $nextJob.ContainsKey('CancelToken')) {
                    $null = $ps.AddParameter("CancelToken", $Cts.Token)
                }
                $handles.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
            }

            $null = Test-PkAbortSignal
            Receive-PkWorkerMessages -Queue $messageQueue
            if ($null -ne $PollCallback) { $null = & $PollCallback }

            $stillPending = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($h in $handles) {
                if ($h.Handle.IsCompleted) {
                    $results = $null
                    try {
                        $results = $h.PS.EndInvoke($h.Handle)
                        if ($h.PS.HadErrors) {
                            foreach ($e in $h.PS.Streams.Error) { Invoke-PkMessageHandler -Message ("Runspace error: " + $e.ToString()) -Level Error }
                        }
                    } catch {
                        # The worker itself threw - there is no result, so
                        # -ResultHandler is never called for this job.
                        $outcome.CrashedCount++
                        Invoke-PkMessageHandler -Message ("Error collecting runspace result: " + $_) -Level Error
                        # Swallowed: a broken crash handler must not take the other workers down with it.
                        if ($null -ne $JobCrashedHandler) { try { $null = & $JobCrashedHandler $_ } catch { } }
                    } finally {
                        $h.PS.Dispose()
                    }
                    if ($null -ne $results) {
                        foreach ($r in $results) { $null = & $ResultHandler $r }
                    }
                } else {
                    $stillPending.Add($h)
                }
            }
            $handles = $stillPending
            if ($handles.Count -gt 0 -and ($scanExhausted -or $handles.Count -ge $MaxParallel)) { [System.Threading.Thread]::Sleep(100) }
        }

        if ($Cts.Token.IsCancellationRequested) {
            $drainArgs = @{ Handles = $handles; ResultHandler = $ResultHandler; MessageQueue = $messageQueue; TimeoutSeconds = $DrainTimeoutSeconds }
            if ($PSBoundParameters.ContainsKey('AbortWaitMessage')) { $drainArgs.AbortWaitMessage = $AbortWaitMessage }
            $drainResult = Invoke-PkGracefulDrain @drainArgs
            $outcome.ForceStoppedCount = $drainResult.ForceStoppedCount
            $outcome.Aborted = $true
        }

        Receive-PkWorkerMessages -Queue $messageQueue
        if ($null -ne $PollCallback) { $null = & $PollCallback }
    } finally {
        # Best-effort teardown; whatever exception is already in flight is the one to surface.
        $stillRunning = $false
        foreach ($h in $handles) {
            try {
                if (-not $h.Handle.IsCompleted) { $stillRunning = $true; $null = $h.PS.BeginStop($null, $null) }
            } catch { }
        }
        if ($null -ne $pool) {
            # A worker stuck inside a .NET call can't be stopped, and
            # Dispose() would sit and wait for it. Close in the background
            # and move on; the abandoned worker ends when it returns or
            # the process exits.
            if ($stillRunning) {
                # An abandoned worker does NOT stop when its blocking call
                # returns - it can run on to its last line. Cancel the token
                # so a worker that checks Test-PkCancelRequested before an
                # irreversible step still gets told, even on a non-abort
                # exit (one of your callbacks threw).
                try { $Cts.Cancel() } catch { }
                try { $null = $pool.BeginClose($null, $null) } catch { }
            }
            else               { try { $pool.Dispose() } catch { } }
        }
        if ($null -ne $messageQueue) { try { Receive-PkWorkerMessages -Queue $messageQueue } catch { } }
        if ($null -ne $ownCts) {
            Unregister-PkCancellationSource -Cts $ownCts
            $ownCts.Dispose()
        }
        if ($registeredCallerCts) { Unregister-PkCancellationSource -Cts $Cts }
    }

    return $outcome
}

# ==============================================================================
#  Worker-safety check (see README.md, "The two rules")
# ==============================================================================

function Get-PkCommandKind {
    # What a worker would need to run $Name: 'Function' (one of your session's
    # functions - must be shared), 'UnloadableModuleFunction' (from a module a
    # worker can't autoload), or 'Other' (cmdlet, program, autoloadable module
    # function, or unknown). Reads the Alias: and Function: drives directly:
    # Get-Command on a name that doesn't resolve searches every module on
    # $env:PSModulePath, and the check runs on every Invoke-PkRunspaceJobs call.
    param([string]$Name)
    $hops = 0
    $alias = Get-Item -LiteralPath ("Alias:\" + $Name) -ErrorAction SilentlyContinue
    while ($null -ne $alias -and $hops -lt 5) {
        $Name = $alias.Definition
        $alias = Get-Item -LiteralPath ("Alias:\" + $Name) -ErrorAction SilentlyContinue
        $hops++
    }
    $fn = Get-Item -LiteralPath ("Function:\" + $Name) -ErrorAction SilentlyContinue
    if ($null -eq $fn) { return 'Other' }
    if ([string]::IsNullOrEmpty($fn.ModuleName)) { return 'Function' }
    # A module function (Get-FileHash, say) autoloads in a worker like a
    # cmdlet does - but only if the module can be found by name. One imported
    # by path from elsewhere can't.
    if ($null -ne (Get-Module -ListAvailable -Name $fn.ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1)) { return 'Other' }
    return 'UnloadableModuleFunction'
}

function Get-PkScriptBlockJobKey {
    # The first key of a job hashtable whose value is a scriptblock, or holds
    # one up to three levels down (in arrays, lists, dictionaries and
    # [pscustomobject]s), else $null. A scriptblock belongs to the runspace
    # that made it: run in a worker it executes against the main thread's
    # session state, which can corrupt it (the kit's own functions vanish
    # mid-run), crash, or hang.
    param([Parameter(Mandatory)][hashtable]$Job)
    foreach ($key in $Job.Keys) {
        if (Test-PkHoldsScriptBlock -Value $Job[$key] -Depth 3) { return [string]$key }
    }
    return $null
}

function Test-PkHoldsScriptBlock {
    # Get-PkScriptBlockJobKey's walk. Leaves (strings, numbers) are checked
    # inline rather than through a call, so a big object[] stays cheap, and
    # a collection whose element type can't hold anything (byte[], string[],
    # List[int]) isn't walked at all.
    param($Value, [int]$Depth)
    if ($null -eq $Value) { return $false }
    if ($Value -is [scriptblock]) { return $true }
    if ($Depth -le 0) { return $false }
    $type = $Value.GetType()
    if ($Value -is [System.Collections.IDictionary]) {
        $items = $Value.Values
    } elseif ($Value -is [System.Collections.IList]) {
        $items = $Value
    } elseif ($type.FullName -eq 'System.Management.Automation.PSCustomObject') {
        $items = foreach ($p in $Value.PSObject.Properties) { if ($p -is [System.Management.Automation.PSNoteProperty]) { $p.Value } }
    } else {
        return $false
    }
    $elementType = $null
    if ($type.IsArray) { $elementType = $type.GetElementType() }
    elseif ($type.IsGenericType) { $genericArgs = $type.GetGenericArguments(); $elementType = $genericArgs[$genericArgs.Length - 1] }
    if ($null -ne $elementType -and ($elementType.IsValueType -or $elementType -eq [string])) { return $false }
    try {
        foreach ($inner in $items) {
            if ($null -eq $inner -or $inner -is [string] -or $inner -is [System.ValueType]) { continue }
            if ($inner -is [scriptblock]) { return $true }
            if ($Depth -gt 1 -and (Test-PkHoldsScriptBlock -Value $inner -Depth ($Depth - 1))) { return $true }
        }
    } catch {
        # A collection other threads are changing (a results sink shared by
        # running workers) can't be enumerated safely; PowerShell may wrap
        # the "collection was modified" error, so catch it whatever its type.
        # Skip the value rather than fail the run: such sinks hold results,
        # not code.
        return $false
    }
    return $false
}

function Get-PkScriptBlockJobMessage {
    # Shared by the fixed-list and -NextJobProvider checks in Invoke-PkRunspaceJobs.
    param([string]$Job, [string]$Key)
    return ("Invoke-PkRunspaceJobs: " + $Job + " passes a scriptblock in '" + $Key + "'. A scriptblock made on the main thread and run in a worker can corrupt, crash or hang the run. " +
        "Pass its text instead (`$sb.ToString()) and rebuild it in the worker with [scriptblock]::Create(`$text), or pass -CheckWorkerSafety:`$false to skip this check.")
}

function Test-PkWorkerSafety {
    # Static check of a worker script and the functions shared with it.
    # Returns a list of findings (empty = clean); each is
    # @{ Rule; Where; Line; Text }. Put "# pk:ignore" on a line to accept it.
    #
    #   MissingFunction  the worker calls one of your functions that isn't in -SharedFunctionNames
    #   ScriptVariable   a shared function (or a nested scriptblock or function in the worker) uses $script:
    #   DelegateCast     worker-reachable code casts a scriptblock to a .NET delegate, or passes
    #                    one straight into a .NET method/constructor (which converts it to one)
    #
    # Not visible from here: commands invoked through a variable (& $cmd).
    # Scriptblocks handed to a worker as job values are refused separately,
    # by Invoke-PkRunspaceJobs (see Get-PkScriptBlockJobKey).
    param(
        [Parameter(Mandatory)]
        [scriptblock]$WorkerScript,
        [string[]]$SharedFunctionNames = @()
    )

    $findings = [System.Collections.Generic.List[hashtable]]::new()
    $kitNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-PkWorkerSafeFunctionNames), [System.StringComparer]::OrdinalIgnoreCase)
    $listed   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $kitNames)            { $null = $listed.Add($n) }
    foreach ($n in $SharedFunctionNames) { $null = $listed.Add($n) }

    # What to check: the worker body, plus every shared function of yours.
    $targets = [System.Collections.Generic.List[hashtable]]::new()
    $targets.Add(@{ Where = 'worker script'; Ast = $WorkerScript.Ast; IsWorkerBody = $true })
    foreach ($n in $SharedFunctionNames) {
        if ($kitNames.Contains($n)) { continue }
        $fn = Get-Item ("Function:\" + $n) -ErrorAction SilentlyContinue
        if ($null -eq $fn) {
            $findings.Add(@{ Rule = 'MissingFunction'; Where = '-SharedFunctionNames'; Line = 0; Text = ("-SharedFunctionNames lists '" + $n + "', which is not a defined function") })
            continue
        }
        $targets.Add(@{ Where = ("function " + $n); Ast = $fn.ScriptBlock.Ast; IsWorkerBody = $false })
    }

    $kindCache = @{}
    foreach ($t in $targets) {
        $ast = $t.Ast

        foreach ($c in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cmdName = $c.GetCommandName()
            if (-not $cmdName) { continue }
            if ($c.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            if (-not $kindCache.ContainsKey($cmdName)) { $kindCache[$cmdName] = Get-PkCommandKind -Name $cmdName }
            $kind = $kindCache[$cmdName]
            if ($kind -eq 'Function' -and -not $listed.Contains($cmdName)) {
                $findings.Add(@{ Rule = 'MissingFunction'; Where = $t.Where; Line = $c.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $c.Extent.StartLineNumber + ") calls '" + $cmdName + "', which is not in -SharedFunctionNames") })
            } elseif ($kind -eq 'UnloadableModuleFunction' -and -not $listed.Contains($cmdName)) {
                $findings.Add(@{ Rule = 'MissingFunction'; Where = $t.Where; Line = $c.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $c.Extent.StartLineNumber + ") calls '" + $cmdName + "', from a module a worker can't load by name (imported by path?) - put the module on `$env:PSModulePath, or list the function in -SharedFunctionNames") })
            }
        }

        # $script: - anywhere in a shared function; only inside NESTED
        # scriptblocks of the worker body (its own top level is fine).
        $scriptVarScopes = [System.Collections.Generic.List[object]]::new()
        if ($t.IsWorkerBody) {
            foreach ($nested in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) { $scriptVarScopes.Add($nested) }
            # A function defined inside the worker script is in the same
            # position as a shared one: called from a closure, its $script:
            # can read as empty.
            foreach ($innerFn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $scriptVarScopes.Add($innerFn.Body) }
        } else {
            $scriptVarScopes.Add($ast)
        }
        $seenRefs = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($scopeAst in $scriptVarScopes) {
            foreach ($ref in $scopeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.IsScript }, $true)) {
                if (-not $seenRefs.Add($ref.Extent.StartOffset)) { continue }
                if ($ref.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
                $findings.Add(@{ Rule = 'ScriptVariable'; Where = $t.Where; Line = $ref.Extent.StartLineNumber
                                 Text = ($t.Where + " (line " + $ref.Extent.StartLineNumber + ") uses `$" + $ref.VariablePath.UserPath + " - it can silently read as empty in a worker") })
            }
        }

        foreach ($cv in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true)) {
            if ($cv.Type.TypeName.Name -notmatch '^(System\.)?(Func|Action|Predicate|Comparison|Converter)(\[|`|$)') { continue }
            if ($cv.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            $findings.Add(@{ Rule = 'DelegateCast'; Where = $t.Where; Line = $cv.Extent.StartLineNumber
                             Text = ($t.Where + " (line " + $cv.Extent.StartLineNumber + ") casts a scriptblock to the delegate [" + $cv.Type.TypeName.Name + "] - this can hang or crash a worker") })
        }

        # The implicit form: a scriptblock literal passed as an argument to
        # a method or constructor - $dict.GetOrAdd($k, { ... }),
        # [System.Lazy[object]]::new({ ... }). No cast is written, but .NET
        # receives a delegate all the same. .ForEach()/.Where() are
        # PowerShell's own and take real scriptblocks, so they're fine.
        # The same goes for a variable assigned a scriptblock literal (or
        # { }.GetNewClosure()) anywhere in this code, then passed as
        # $lazy = [System.Lazy[object]]::new($factory). By name, not by flow:
        # a variable reassigned to something else in between is still flagged.
        # Methods that only store a value in a collection ($list.Add($sb),
        # $map.Add($k, $sb), $queue.Enqueue($sb)) aren't flagged: storing a
        # scriptblock makes no delegate. Not caught as a result: a collection
        # typed to hold delegates (List[Func[object]]), where .Add converts.
        $storageMethods = @('Add', 'AddRange', 'Insert', 'Enqueue', 'Push', 'TryAdd', 'Contains', 'Remove', 'IndexOf', 'set_Item')
        $scriptBlockVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assign in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $target = $assign.Left
            if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
            if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $rhs = $assign.Right
            if ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1) { $rhs = $rhs.PipelineElements[0] }
            if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
            if ($rhs -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$rhs.Member.Extent.Text -eq 'GetNewClosure') { $rhs = $rhs.Expression }
            if ($rhs -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $null = $scriptBlockVars.Add($target.VariablePath.UserPath) }
        }
        foreach ($call in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($null -eq $call.Arguments) { continue }
            $memberName = [string]$call.Member.Extent.Text
            if ($memberName -in @('ForEach', 'Where')) { continue }
            if ($memberName -in $storageMethods) { continue }
            $passed = $null
            foreach ($argument in $call.Arguments) {
                if ($argument -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $passed = 'a scriptblock' }
                elseif ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $scriptBlockVars.Contains($argument.VariablePath.UserPath)) {
                    $passed = ("the scriptblock in `$" + $argument.VariablePath.UserPath)
                }
            }
            if ($null -eq $passed) { continue }
            if ($call.Extent.StartScriptPosition.Line -match '#\s*pk:ignore') { continue }
            $findings.Add(@{ Rule = 'DelegateCast'; Where = $t.Where; Line = $call.Extent.StartLineNumber
                             Text = ($t.Where + " (line " + $call.Extent.StartLineNumber + ") passes " + $passed + " to ." + $memberName + "() - .NET turns it into a delegate, which can hang or crash a worker (add '# pk:ignore' if this method really takes a scriptblock)") })
        }
    }

    return ,$findings
}
