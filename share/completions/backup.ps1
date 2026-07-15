Register-ArgumentCompleter -Native -CommandName backup -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $options = @('--help', '--help-advanced', '--version', '--manifest', '--deterministic', '--dry-run', '--list', '--list-json', '--verify', '--extract', '--output-dir', '--only', '--exclude', '--skip-existing', '--overwrite', '--rename-existing', '--compression','--compression=', '--symlinks', '--ignore', '--prefix', '--max-file-size', '--max-total-size', '--encrypt', '--password-file', '--password-env', '--password-prompt', '--cipher', '--catalog', '--index', '--query', '--list-archives', '--list-contents', '--verify-catalog', '--remote', '--remote-config', '--upload', '--sync', '--restore-remote', '--remote-require-encrypted', '--remote-resume', '--create-job', '--run-job', '--job', '--retention-policy', '--incremental-from', '--incremental-from-manifest', '--json-errors', '--pcloud-oauth-url', '--pcloud-oauth-token', '--proton-drive-login', '--pcloud-clean-temp', '--pcloud-check')
    $values = @{
        '--compression' = @('auto','store','deflate','bzip2','lzma','zstd')
        '--symlinks' = @('skip','store-link','follow')
        '--cipher' = @('aes256-gcm')
        '--retention-policy' = @('count:','daily:','weekly:','monthly:','tiered:')
    }
    $tokens = $commandAst.CommandElements | ForEach-Object { $_.Extent.Text }
    $previous = if ($tokens.Count -gt 1) { $tokens[$tokens.Count - 2] } else { '' }
    if ($previous -eq '--password-env') {
        Get-ChildItem Env: | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object { $_.Name }
        return
    }
    if ($values.ContainsKey($previous)) {
        $values[$previous] | Where-Object { $_ -like "$wordToComplete*" }
        return
    }
    if ($wordToComplete -like '--*=*') {
        $parts = $wordToComplete.Split('=', 2)
        if ($values.ContainsKey($parts[0])) {
            $values[$parts[0]] | Where-Object { $_ -like "$($parts[1])*" } | ForEach-Object { "$($parts[0])=$_" }
            return
        }
    }
    $options | Where-Object { $_ -like "$wordToComplete*" }
}
