#!/bin/sh
#测试修复超级块
## 1. 卸载
#umount /dev/mmcblk0p21
#
## 2. 覆盖整个分区前 300KB（主超级块 + 前几个备份超级块）
#dd if=/dev/zero of=/dev/mmcblk0p21 bs=1k count=300 conv=notrunc
#
## 3. 确认 file 检测不到 ext4
#file -s /dev/mmcblk0p21
#
## 4. 运行脚本——此时应该无法修复，最终执行 mkfs.ext4
#sh ext4_repair.sh
#
## 5. 验证是否被格式化
#file -s /dev/mmcblk0p21
## 应该显示新的 ext4 filesystem
#
DEV=/dev/mmcblk0p21
umount $DEV 2>/dev/null

# 强制进入修复分支（绕过 file 检测）
if true; then
    echo "[TEST] Entering repair branch" > /dev/console
    
    SB_LIST=$(mke2fs -n -F $DEV 2>/dev/null | awk '/Superblock backups/{getline; print}' | tr ',' ' ')
    echo "[TEST] SB_LIST=$SB_LIST" > /dev/console
    
    [ -z "$SB_LIST" ] && SB_LIST="8193 24577 40961 32768 98304 163840"
    
    for sb in $SB_LIST; do
        echo "[TEST] Trying superblock $sb" > /dev/console
        e2fsck -b $sb -y $DEV >/dev/null 2>&1
        ret=$?
        echo "[TEST] e2fsck returned $ret" > /dev/console
        [ $ret -le 2 ] && break
    done
    
    file -s $DEV | grep -q ext4 || echo "[TEST] Would format here" > /dev/console
fi
