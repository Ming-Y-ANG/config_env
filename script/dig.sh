#!/bin/sh
# find_proc_using_mount.sh - 查找占用指定挂载点的进程
# 用法: ./find_proc_using_mount.sh /tmp/app

TARGET="${1:-/tmp/app}"
TARGET=$(readlink -f "$TARGET")  # 转为绝对路径，去除末尾斜杠等
[ -z "$TARGET" ] && { echo "Usage: $0 <mountpoint>"; exit 1; }

echo "Scanning for processes using: $TARGET"
echo "========================================"

# 确保 TARGET 末尾没有 /，方便前缀匹配
TARGET="${TARGET%/}"

# 遍历所有进程
for pid_dir in /proc/[0-9]*; do
    pid=$(basename "$pid_dir")
    
    # 跳过不存在的进程（可能刚好退出）
    [ -d "$pid_dir" ] || continue
    
    found=0
    reason=""
    
    # ---- 1. 检查 CWD ----
    if [ -L "$pid_dir/cwd" ]; then
        cwd=$(readlink -f "$pid_dir/cwd" 2>/dev/null)
        case "$cwd" in
            "$TARGET"|"$TARGET"/*)
                found=1
                reason="cwd=$cwd"
                ;;
        esac
    fi
    
    # ---- 2. 检查 ROOT (chroot) ----
    if [ $found -eq 0 ] && [ -L "$pid_dir/root" ]; then
        root=$(readlink -f "$pid_dir/root" 2>/dev/null)
        case "$root" in
            "$TARGET"|"$TARGET"/*)
                found=1
                reason="root=$root"
                ;;
        esac
    fi
    
    # ---- 3. 检查打开的文件描述符 ----
    if [ $found -eq 0 ] && [ -d "$pid_dir/fd" ]; then
        for fd in "$pid_dir/fd"/*; do
            [ -L "$fd" ] || continue
            fd_target=$(readlink -f "$fd" 2>/dev/null)
            case "$fd_target" in
                "$TARGET"|"$TARGET"/*)
                    found=1
                    reason="fd=$(basename "$fd") -> $fd_target"
                    break
                    ;;
            esac
        done
    fi
    
    # ---- 4. 检查内存映射 (maps) ----
    # 注意：maps 文件可能很大，这里只 grep 前缀，在嵌入式设备上要小心性能
    if [ $found -eq 0 ] && [ -r "$pid_dir/maps" ]; then
        match=$(awk -v target="$TARGET" '
            BEGIN { found=0 }
            {
                for(i=1; i<=NF; i++) {
                    if ($i ~ "^" target) {
                        print $i
                        found=1
                        exit
                    }
                }
            }
            END { exit !found }
        ' "$pid_dir/maps" 2>/dev/null)
        if [ -n "$match" ]; then
            found=1
            reason="maps -> $match"
        fi
    fi
    
    # ---- 输出结果 ----
    if [ $found -eq 1 ]; then
        comm=$(cat "$pid_dir/comm" 2>/dev/null || echo "unknown")
        printf "PID %-6s [%s] %s\n" "$pid" "$comm" "$reason"
    fi
done
