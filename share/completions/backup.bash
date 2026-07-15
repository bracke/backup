# bash completion for backup
_backup_complete() {
    local cur prev opt value
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        --compression) COMPREPLY=( $(compgen -W "auto store deflate bzip2 lzma zstd" -- "$cur") ); return ;;
        --symlinks) COMPREPLY=( $(compgen -W "skip store-link follow" -- "$cur") ); return ;;
        --cipher) COMPREPLY=( $(compgen -W "aes256-gcm" -- "$cur") ); return ;;
        --retention-policy) COMPREPLY=( $(compgen -W "count: daily: weekly: monthly: tiered:" -- "$cur") ); return ;;
        --password-env) COMPREPLY=( $(compgen -A variable -- "$cur") ); return ;;
        --list|--verify|--extract|--output-dir|--ignore|--password-file|--catalog|--index|--remote-config|--create-job|--run-job|--job|--incremental-from|--incremental-from-manifest)
            COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
    esac

    if [[ "$cur" == --*=* ]]; then
        opt="${cur%%=*}"
        value="${cur#*=}"
        case "$opt" in
            --compression) COMPREPLY=( $(compgen -W "auto store deflate bzip2 lzma zstd" -- "$value") ); COMPREPLY=( "${COMPREPLY[@]/#/--compression=}" ); return ;;
            --symlinks) COMPREPLY=( $(compgen -W "skip store-link follow" -- "$value") ); COMPREPLY=( "${COMPREPLY[@]/#/--symlinks=}" ); return ;;
            --cipher) COMPREPLY=( $(compgen -W "aes256-gcm" -- "$value") ); COMPREPLY=( "${COMPREPLY[@]/#/--cipher=}" ); return ;;
            --retention-policy) COMPREPLY=( $(compgen -W "count: daily: weekly: monthly: tiered:" -- "$value") ); COMPREPLY=( "${COMPREPLY[@]/#/--retention-policy=}" ); return ;;
            --password-env) COMPREPLY=( $(compgen -A variable -- "$value") ); COMPREPLY=( "${COMPREPLY[@]/#/--password-env=}" ); return ;;
        esac
    fi

    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "--help --help-advanced --version --manifest --deterministic --dry-run --list --list-json --verify --extract --output-dir --only --exclude --skip-existing --overwrite --rename-existing --compression --symlinks --ignore --prefix --max-file-size --max-total-size --encrypt --password-file --password-env --password-prompt --cipher --catalog --index --query --list-archives --list-contents --verify-catalog --remote --remote-config --upload --sync --restore-remote --remote-require-encrypted --remote-resume --create-job --run-job --job --retention-policy --incremental-from --incremental-from-manifest --json-errors --pcloud-oauth-url --pcloud-oauth-token --proton-drive-login --pcloud-clean-temp --pcloud-check" -- "$cur") )
    else
        COMPREPLY=( $(compgen -f -- "$cur") )
    fi
}
complete -F _backup_complete backup
