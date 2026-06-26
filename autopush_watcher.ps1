# LFB Contractor Portal - Auto Push Watcher
# Watches for file changes and automatically commits + pushes to GitHub
# Runs silently in the background

$repoPath = "C:\Users\User\Desktop\lfb-contractor-portal"
$logFile = "$repoPath\autopush_log.txt"

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -Append -FilePath $logFile
}

Write-Log "Auto-push watcher started."

Set-Location $repoPath

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $repoPath
$watcher.Filter = "*.*"
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true

# Ignore git internals and the log file itself
$ignore = @(".git", "autopush_log.txt", "autopush_watcher.ps1", "SETUP_AUTOPUSH.bat", "PUSH_TO_LIVE.bat", "INIT_GIT.bat", "tmp_import.sql")

$debounceTimer = $null
$pendingChange = $false

$action = {
    $path = $Event.SourceEventArgs.FullPath
    # Skip ignored files/folders
    foreach ($ig in $ignore) {
        if ($path -like "*$ig*") { return }
    }
    $script:pendingChange = $true
}

Register-ObjectEvent $watcher "Changed" -Action $action | Out-Null
Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Deleted" -Action $action | Out-Null
Register-ObjectEvent $watcher "Renamed" -Action $action | Out-Null

Write-Log "Watching folder: $repoPath"

# Main loop - check every 3 seconds, push if changes detected
while ($true) {
    Start-Sleep -Seconds 3

    if ($pendingChange) {
        $pendingChange = $false
        Start-Sleep -Seconds 2  # debounce: wait for writes to settle

        try {
            Set-Location $repoPath
            $status = git status --porcelain 2>&1
            if ($status) {
                Write-Log "Changes detected: $status"
                git add -A 2>&1 | Out-Null
                $commitMsg = "Auto-update $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
                git commit -m $commitMsg 2>&1 | Out-Null
                $pushResult = git push origin HEAD:main 2>&1
                Write-Log "Pushed: $pushResult"
            }
        } catch {
            Write-Log "Error: $_"
        }
    }
}
