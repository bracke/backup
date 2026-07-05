# fish completion for backup
complete -c backup -l help
complete -c backup -l help-advanced
complete -c backup -l version
complete -c backup -l manifest
complete -c backup -l deterministic
complete -c backup -l dry-run
complete -c backup -l list -r -F
complete -c backup -l list-json
complete -c backup -l verify -r -F
complete -c backup -l extract -r -F
complete -c backup -l output-dir -r -F
complete -c backup -l only
complete -c backup -l exclude
complete -c backup -l skip-existing
complete -c backup -l overwrite
complete -c backup -l rename-existing
complete -c backup -l compression -x -a 'auto store deflate bzip2 lzma ppmd zstd' -d 'Compression mode'
complete -c backup -l symlinks -x -a 'skip store-link follow' -d 'Symlink handling'
complete -c backup -l ignore -r -F
complete -c backup -l prefix
complete -c backup -l max-file-size
complete -c backup -l max-total-size
complete -c backup -l encrypt
complete -c backup -l password-file -r -F
complete -c backup -l password-env -x -a '(set -n)' -d 'Password environment variable'
complete -c backup -l password-prompt
complete -c backup -l cipher -x -a 'aes256-gcm' -d 'Encryption cipher'
complete -c backup -l catalog -r -F
complete -c backup -l index -r -F
complete -c backup -l query
complete -c backup -l list-archives
complete -c backup -l list-contents
complete -c backup -l verify-catalog
complete -c backup -l remote
complete -c backup -l remote-config -r -F
complete -c backup -l upload
complete -c backup -l sync
complete -c backup -l restore-remote
complete -c backup -l remote-require-encrypted
complete -c backup -l remote-resume
complete -c backup -l create-job -r -F
complete -c backup -l run-job -r -F
complete -c backup -l job -r -F
complete -c backup -l retention-policy -x -a 'count: daily: weekly: monthly: tiered:' -d 'Retention policy'
complete -c backup -l incremental-from -r -F
complete -c backup -l incremental-from-manifest -r -F
complete -c backup -l json-errors
complete -c backup -l pcloud-oauth-url
complete -c backup -l pcloud-oauth-token
complete -c backup -l proton-drive-login
complete -c backup -l pcloud-clean-temp
complete -c backup -l pcloud-check
