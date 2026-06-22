#!/bin/bash

INPUT="${1:-trace.raw}"
OUTPUT="${2:-trace.resolved}"

if [ ! -f "$INPUT" ]; then
    echo "Error: $INPUT not found" >&2
    exit 1
fi

> "$OUTPUT"

while IFS= read -r line; do
    resolved=""
    
    # 自动提取 module(+0xoffset) 模式
    full_match=$(echo "$line" | grep -oP '[^ ]+\([\+]?0x[0-9a-f]+\)')
    
    if [ -n "$full_match" ]; then
        # 分离模块路径
        module=$(echo "$full_match" | sed 's/(.*//')
        
        # 分离偏移地址
        offset=$(echo "$full_match" | grep -oP '0x[0-9a-f]+')
        
        # 相对路径 ./xxx 确保存在
        if [[ "$module" == ./* ]] && [ ! -f "$module" ]; then
            module=""
        fi
        
        # 解析符号
        if [ -n "$module" ] && [ -n "$offset" ] && [ -f "$module" ]; then
            name=$(addr2line -f -e "$module" -C "$offset" 2>/dev/null | head -1)
            if [ -n "$name" ] && [ "$name" != "??" ]; then
                resolved="$name"
            fi
        fi
    fi
    
    # 输出
    if [ -n "$resolved" ]; then
        echo "$line  ($resolved)" >> "$OUTPUT"
    else
        echo "$line" >> "$OUTPUT"
    fi
done < "$INPUT"

echo "Resolved: $OUTPUT" >&2
