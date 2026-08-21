#!/bin/sh
# =============================================================================
# 函数：emmc_diagnose
# 描述：收集 eMMC 故障现场诊断信息，适用于 BusyBox / 嵌入式 Linux
# 依赖：基本命令（dmesg, cat, echo, fdisk, dd, fsck, 等）
# 输出：诊断文件存放于 ${EMMC_DIAG_DIR}，可选网络发送
# =============================================================================

# ========================= 可配置变量（默认值） =============================
# 用户可在调用前修改这些环境变量，或直接修改下方默认值

: "${EMMC_DIAG_DEV:=/dev/mmcblk0}"              # eMMC 块设备
: "${EMMC_DIAG_DIR:=/tmp}"                      # 诊断输出目录（必须可写）
: "${EMMC_DIAG_SEND_TO:=}"                      # 发送目标，如 "192.168.1.100:514"，留空则跳过
: "${EMMC_DIAG_SEND_CMD:=nc -w 2}"              # 发送命令（需支持 UDP/TCP）
: "${EMMC_DIAG_EXTRA_CMDS:=}"                   # 额外诊断命令，用分号分隔，如 "i2cdetect -y 0; gpio status"
: "${EMMC_DIAG_DO_DD_READ:=0}"                  # 是否执行 dd 读测试（1=启用，0=禁用）
: "${EMMC_DIAG_DO_FSCK:=1}"                     # 是否执行 fsck 只读检查（1=启用，0=禁用）
: "${EMMC_DIAG_FSCK_DEV:=p17 p18 p19 p20 p21}"  # 指定要检查的分区，留空则自动检查所有已识别分区
# =============================================================================

emmc_diagnose() {
    # ---------- 0. 初始化 ----------
    local dev="${EMMC_DIAG_DEV}"
    local outdir="${EMMC_DIAG_DIR}"
    local send_to="${EMMC_DIAG_SEND_TO}"
    local send_cmd="${EMMC_DIAG_SEND_CMD}"
    local extra_cmds="${EMMC_DIAG_EXTRA_CMDS}"
    local do_dd="${EMMC_DIAG_DO_DD_READ}"
    local do_fsck="${EMMC_DIAG_DO_FSCK}"
    local fsck_dev="${EMMC_DIAG_FSCK_DEV}"

    # 如果目录不存在则创建
    mkdir -p "${outdir}" 2>/dev/null || {
        echo "ERROR: Cannot create output dir ${outdir}" >&2
        return 1
    }

    # 时间戳文件，便于区分多次诊断
    local ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "unknown")
    local base="emmc_diag_${ts}"
    local report="${outdir}/${base}.txt"

    # 日志输出函数（同时写入文件和控制台）
    _log() {
        echo "$*" | tee -a "${report}"
    }

    _log "=== eMMC Diagnostic Report (started at $(date)) ==="
    _log "Device: ${dev}"
    _log "Output: ${outdir}"

    # ---------- 1. 系统基本信息 ----------
    _log ""
    _log "--- System Information ---"
    uname -a >> "${report}" 2>&1
    cat /proc/version >> "${report}" 2>&1
    #cat /proc/cmdline >> "${report}" 2>&1

    # ---------- 2. 内核日志 (dmesg) ----------
    _log ""
    _log "--- Kernel Ring Buffer (dmesg) ---"
    if command -v dmesg >/dev/null 2>&1; then
        dmesg >> "${report}" 2>&1
    else
        _log "WARN: dmesg not found, skipped."
    fi

    # ---------- 3. 系统日志 (如果存在) ----------
    #_log ""
    #_log "--- System Logs (last 100 lines from /var/log/messages, syslog) ---"
    #for logf in /var/log/messages /var/log/syslog; do
    #    if [ -r "${logf}" ]; then
    #        tail -n 100 "${logf}" >> "${report}" 2>&1
    #    fi
    #done

    # ---------- 4. eMMC 设备 sysfs 信息 ----------
    _log ""
    _log "--- eMMC sysfs Attributes ---"
    local sysfs_dir="/sys/class/block/$(basename ${dev})/device"
    if [ -d "${sysfs_dir}" ]; then
        # 列举常用属性文件
        for attr in name manfid oemid serial date fwrev cid csd pre_eol_info life_time erase_size rev; do
            if [ -r "${sysfs_dir}/${attr}" ]; then
                printf "%-15s: " "${attr}" >> "${report}"
                cat "${sysfs_dir}/${attr}" >> "${report}" 2>&1
            fi
        done
        # 如果存在 ext_csd 二进制，尝试 hexdump
        if [ -r "${sysfs_dir}/ext_csd" ]; then
            _log "--- ext_csd (hexdump) ---"
            if command -v hexdump >/dev/null 2>&1; then
                hexdump -C "${sysfs_dir}/ext_csd" >> "${report}" 2>&1
            elif command -v od >/dev/null 2>&1; then
                od -tx1 "${sysfs_dir}/ext_csd" >> "${report}" 2>&1
            else
                _log "WARN: no hexdump/od, ext_csd content not shown."
            fi
        fi
    else
        _log "WARN: sysfs path ${sysfs_dir} not found."
    fi

    # ---------- 5. 块设备统计----------
    #_log ""
    #_log "--- Block Device Statistics (/sys/block/$(basename ${dev})/stat) ---"
    #if [ -r "/sys/block/$(basename ${dev})/stat" ]; then
    #    cat "/sys/block/$(basename ${dev})/stat" >> "${report}" 2>&1
    #fi

    # ---------- 6. 分区表 ----------
    _log ""
    _log "--- Partition Table (fdisk -l) ---"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "${dev}" >> "${report}" 2>&1
    else
        _log "WARN: fdisk not found, skipped."
    fi

    # ---------- 7. 文件系统检查 (只读) ----------
    if [ "${do_fsck}" -eq 1 ]; then
        _log ""
        _log "--- Filesystem Check (read-only) ---"
        if [ -z "${fsck_dev}" ]; then
            # 自动查找所有分区（从 fdisk 输出中提取）
            if command -v fdisk >/dev/null 2>&1; then
                local parts=$(fdisk -l "${dev}" 2>/dev/null | grep -E "^${dev}p[0-9]+" | awk '{print $1}')
                [ -z "${parts}" ] && parts=$(fdisk -l "${dev}" 2>/dev/null | grep -E "^${dev}[0-9]+" | awk '{print $1}')
                if [ -n "${parts}" ]; then
                    for p in ${parts}; do
                        _log "Checking $p ..."
                        if command -v e2fsck >/dev/null 2>&1; then
                            e2fsck -n "${p}" >> "${report}" 2>&1
                        elif command -v fsck >/dev/null 2>&1; then
                            fsck -N -n "${p}" >> "${report}" 2>&1   # -N 不真正执行，仅显示
                            fsck -n "${p}" >> "${report}" 2>&1
                        else
                            _log "WARN: fsck not found, cannot check."
                        fi
                    done
                else
                    _log "No partitions found for fsck."
                fi
            else
                _log "WARN: fdisk missing, cannot auto-detect partitions."
            fi
        else
            # 用户指定了分区
			for p in ${fsck_dev}; do
				local part=$dev$p
				_log "Checking $part ..."
				if command -v e2fsck >/dev/null 2>&1; then
					e2fsck -n "${part}" >> "${report}" 2>&1
				elif command -v fsck >/dev/null 2>&1; then
					fsck -n "${part}" >> "${report}" 2>&1
				else
					_log "WARN: fsck not found, skipped."
				fi
			done
        fi
    fi

    # ---------- 8. DD 读取测试 ----------
    if [ "${do_dd}" -eq 1 ]; then
        _log ""
        _log "--- DD Read Test (first 1MB, skip if too slow) ---"
        # 读取前 1MB，跳过可能破坏数据的风险
        if command -v dd >/dev/null 2>&1; then
            dd if="${dev}" of=/dev/null bs=512 count=2048 2>&1 | grep -E 'error|bytes|records' >> "${report}" 2>&1
        else
            _log "WARN: dd not found, skipped."
        fi
    fi

    # ---------- 9. 执行额外诊断命令 ----------
    if [ -n "${extra_cmds}" ]; then
        _log ""
        _log "--- Extra Diagnostic Commands ---"
        OLD_IFS="$IFS"; IFS=';'
        for cmd in ${extra_cmds}; do
            IFS="$OLD_IFS"
            _log "> ${cmd}"
            eval "${cmd}" >> "${report}" 2>&1
        done
        IFS="$OLD_IFS"
    fi

    # ---------- 10. 汇总信息 ----------
    _log ""
    _log "Diagnostic report saved to: ${report}"
    #ls -la "${outdir}" >> "${report}" 2>&1

    # ---------- 11. 网络发送（如果配置） ----------
    if [ -n "${send_to}" ]; then
        _log ""
        _log "Attempting to send report to ${send_to} ..."
        if command -v nc >/dev/null 2>&1 || command -v netcat >/dev/null 2>&1; then
            # 尝试使用 nc 或 netcat
            local nc_cmd="nc"
            command -v nc >/dev/null 2>&1 || nc_cmd="netcat"
            # 分离 host 和 port
            local host="${send_to%:*}"
            local port="${send_to##*:}"
            if [ -n "${host}" ] && [ -n "${port}" ]; then
                (cat "${report}" | ${send_cmd} "${host}" "${port}") 2>/dev/null && _log "Send OK" || _log "Send FAILED"
            else
                _log "Invalid send_to format, expected host:port"
            fi
        else
            _log "WARN: nc/netcat not found, cannot send."
        fi
    fi

    _log "=== End of diagnostic report ==="
    return 0
}
