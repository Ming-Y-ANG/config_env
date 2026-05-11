#!/bin/sh
### BEGIN INIT INFO
# Provides:          ramoops-backup
# Required-Start:    $local_fs $syslog
# Required-Stop:
# Default-Start:     S
# Default-Stop:
# Short-Description: Persist ramoops logs to /var/backups
### END INIT INFO

PSTORE_DIR="/sys/fs/pstore"
BACKUP_DIR="/var/backups/ramoops"
SEQ_FILE="$BACKUP_DIR/.seq"
LOG_FILE="$BACKUP_DIR/.save.log"
MAX_SIZE=41943040
LOG_MAX_SIZE=1048576

# 1. 依赖检查
if ! command -v gzip >/dev/null 2>&1; then
    echo "ramoops-backup: gzip not found" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR" || {
    echo "ramoops-backup: failed to create $BACKUP_DIR" >&2
    exit 1
}

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# 日志截断（超过 1MB 时清空）
if [ -f "$LOG_FILE" ]; then
    log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    case "$log_size" in
        ''|*[!0-9]*) log_size=0 ;;
    esac
    if [ "$log_size" -ge "$LOG_MAX_SIZE" ]; then
        : > "$LOG_FILE"
        log_msg "LOG truncated (was ${log_size}B)"
    fi
fi

# 2. 检查备份目录大小，超过 40M 直接返回
dir_size=0
for f in "$BACKUP_DIR"/*; do
    [ -f "$f" ] || continue
    s=$(wc -c < "$f" 2>/dev/null | awk '{print $1}')
    case "$s" in
        ''|*[!0-9]*) s=0 ;;
    esac
    dir_size=$((dir_size + s))
done

if [ "$dir_size" -ge "$MAX_SIZE" ]; then
    log_msg "SKIP backup dir ${dir_size}B >= ${MAX_SIZE}B limit"
    exit 0
fi

# 3. 获取下一个序列号（0001, 0002...）
next_seq() {
    _seq=0
    if [ -s "$SEQ_FILE" ]; then
        read -r _seq < "$SEQ_FILE" 2>/dev/null
        case "$_seq" in
            ''|*[!0-9]*) _seq=0 ;;
        esac
    fi
    _seq=$((_seq + 1))
    if ! printf '%04d\n' "$_seq" > "$SEQ_FILE"; then
        echo "seq-write-failed"
        return 1
    fi
    printf '%04d' "$_seq"
}

# 4. 清理临时文件
cleanup_tmp() {
    rm -f "$BACKUP_DIR"/.tmp.*.$$
}
trap cleanup_tmp EXIT INT TERM

# 5. 遍历 pstore 中所有文件（包含 ramoops/oops/mce 等）
saved=0
for src in "$PSTORE_DIR"/*; do
    [ -e "$src" ] || continue
    [ -f "$src" ] || continue

    name=$(basename "$src")
    seq=$(next_seq) || {
        log_msg "FAIL $name seq update error (disk full?)"
        continue
    }

    dst_name="${seq}_${name}.gz"
    tmp="$BACKUP_DIR/.tmp.${seq}.$$"

    if gzip -c "$src" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        if mv -f "$tmp" "$BACKUP_DIR/$dst_name"; then
            size=$(wc -c < "$BACKUP_DIR/$dst_name" 2>/dev/null | awk '{print $1}')
            case "$size" in
                ''|*[!0-9]*) size=0 ;;
            esac
            if rm -f "$src" 2>/dev/null; then
                log_msg "SAVE $name -> $dst_name (${size}B)"
                saved=1
            else
                log_msg "WARN $name saved but remove source failed"
                saved=1
            fi
        else
            rm -f "$tmp"
            log_msg "FAIL $name rename error"
        fi
    else
        rm -f "$tmp"
        log_msg "FAIL $name compress error (empty or unreadable)"
    fi
done

# 6. 有变更则 sync 落盘
[ "$saved" -eq 1 ] && sync
exit 0
