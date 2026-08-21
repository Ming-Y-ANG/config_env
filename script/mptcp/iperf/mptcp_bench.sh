#!/bin/bash
# mptcp_bench.sh — MPTCP 聚合系统三步基准测试（全部在 PC 上运行）
#
# 拓扑：PC -> GW(MPTCP聚合, WEB配置) -> 蜂窝1/蜂窝2 -> VPS -> test server
#
# 使用方式（三步，链路状态全部由你在 GW 的 WEB 页面配置）：
#   ① WEB 开聚合（双蜂窝工作）   → SCENARIO=agg   bash mptcp_bench.sh
#   ② WEB 只留蜂窝1工作          → SCENARIO=cell1 bash mptcp_bench.sh
#   ③ WEB 只留蜂窝2工作          → SCENARIO=cell2 bash mptcp_bench.sh
#   三次结果落同一 RESULTS_DIR，最后合并汇总：
#     RESULTS_DIR=./res1 MODE=summary bash mptcp_bench.sh
#
# MODE=tput(默认)|latency|failover|summary|all
#   tput     吞吐：-P 并行流扫描 × 上下行 × 重复，iperf -O 剔除爬坡
#   latency  延迟/抖动/丢包：PC→test server ping 统计
#   failover 故障切换（仅 agg）：测试中按提示在 WEB 上断/恢复一条蜂窝
#   summary  只合并汇总，不连设备
#
set -u

# ═══════════════ CONFIG（按你的环境修改） ═══════════════
GW_SSH="${GW_SSH:-adm@192.168.2.1}"                        # GW 地址（留空=不连接，跳过路径验证；填了则只读接口字节计数）
GW_PASS="${GW_PASS:-123456}"                      # GW 的 SSH 密码（用 sshpass 自动登录；已配免密 key 则留空）
GW_IF_A="${GW_IF_A:-apn01}"                 # 蜂窝1 接口名
GW_IF_B="${GW_IF_B:-apn11}"                 # 蜂窝2 接口名
TEST_TARGET="${TEST_TARGET:-47.108.191.116}"   # PC 经隧道可达的测试目标
# 注意：脚本不登录 test server。请提前在 ts 上手动常驻 iperf3 服务端：
#   iperf3 -s -p 65000        （前台，或加 -D 后台常驻）

IPERF_PORT="${IPERF_PORT:-65000}"
# ── 测试规模（控制时长和流量消耗） ──────────────────────────
# 默认精简配置：1方向 × 2个P值 × 2轮 = 4次×10秒 ≈ 1分钟/场景，流量约几百MB
# 要完整矩阵可恢复：DIRECTIONS="up down" PVALUES="1 2 4 8 16" REPEAT=3 DURATION=15
DIRECTIONS="${DIRECTIONS:-up down}"         # up down=双向 | up=仅上行（流量减半）
PVALUES="${PVALUES:-1}"                   # 1 测单流能力，8 测聚合上限（2/4/16 信息量低，已砍）
REPEAT="${REPEAT:-3}"                       # 重复轮数（2轮可判稳定性，3轮更严但+50%消耗）
DURATION="${DURATION:-20}"                  # 单次吞吐时长(秒)
WARMUP="${WARMUP:-3}"                       # iperf -O 爬坡剔除(秒)
PING_COUNT="${PING_COUNT:-100}"             # latency 场景的 ping 次数

# failover 时间轴（已压缩：10s 基线 → 断链 15s → 恢复观察 15s，共 40s）
FO_DURATION="${FO_DURATION:-60}"            # failover 总时长(秒)
FO_DOWN_AT="${FO_DOWN_AT:-10}"              # 提示断链的时间点
FO_UP_AT="${FO_UP_AT:-25}"                  # 提示恢复的时间点
FO_RECOVER_PCT="${FO_RECOVER_PCT:-80}"      # 恢复到断前均值百分比视为已恢复
# 可选限速（如 FO_BITRATE=80M 则 iperf 加 -b 限速打流，省流量）。
# 注意：限速值必须高于单链路能力，否则断一路后吞吐不跌，测不出切换效果；
# 不确定就留空（全速）。
FO_BITRATE="${FO_BITRATE:-}"

SCENARIO="${SCENARIO:-}"                    # agg|cell1|cell2（不设则交互选择）
MODE="${MODE:-}"                            # tput|latency|failover|all|summary（不设则交互选择）
ASSUME_YES="${ASSUME_YES:-0}"               # 1=跳过场景/模式确认
RESULTS_DIR="${RESULTS_DIR:-./bench_results}"
CLEAN="${CLEAN:-0}"                         # 1=开跑前清空 CSV 旧数据（见下）
# ═══════════════════════════════════════════════════════════

mkdir -p "$RESULTS_DIR"
CSV_TPUT="$RESULTS_DIR/throughput.csv"
CSV_FO="$RESULTS_DIR/failover.csv"
CSV_LAT="$RESULTS_DIR/latency.csv"
# CSV 追加写入（支持 agg/cell1/cell2 分次跑后合并）；CLEAN=1 时先清空旧数据
[ "$CLEAN" = "1" ] && rm -f "$CSV_TPUT" "$CSV_FO" "$CSV_LAT"
[ -f "$CSV_TPUT" ] || echo "scenario,direction,P,rep,bw_mbps,retrans,pathA_bytes,pathB_bytes,status" >"$CSV_TPUT"
[ -f "$CSV_FO" ]   || echo "scenario,lost_pings,loss_window_s,tput_dip_pct,recover_s,status" >"$CSV_FO"
[ -f "$CSV_LAT" ]  || echo "scenario,ts,sent,loss_pct,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms" >"$CSV_LAT"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# ── 模式选择 ──────────────────────────────────────────────
pick_mode() {
    if [ -z "$MODE" ]; then
        echo "请选择测试内容："
        echo "  1) tput     —— 吞吐测试（并行流 × 上下行 × 重复）"
        echo "  2) latency  —— 延迟/抖动/丢包（ping $PING_COUNT 次）"
        echo "  3) failover —— 故障切换（仅 agg 场景，${FO_DURATION}s）"
        echo "  4) all      —— 以上全部"
        echo "  5) summary  —— 仅合并汇总已有结果（不连设备）"
        printf '输入 1-5 [默认 1]: '; read -r m
        case "${m:-1}" in
            1) MODE=tput ;; 2) MODE=latency ;; 3) MODE=failover ;;
            4) MODE=all ;; 5) MODE=summary ;;
            *) echo "无效选择" >&2; exit 1 ;;
        esac
    fi
    case "$MODE" in tput|latency|failover|all|summary) ;;
        *) echo "MODE 须为 tput|latency|failover|all|summary" >&2; exit 1 ;; esac
}

# ── 场景选择 ──────────────────────────────────────────────
pick_scenario() {
    if [ -z "$SCENARIO" ]; then
        echo "请选择当前 WEB 上已配置好的链路状态："
        echo "  1) agg   —— 聚合开启，双蜂窝同时工作"
        echo "  2) cell1 —— 仅蜂窝1工作"
        echo "  3) cell2 —— 仅蜂窝2工作"
        printf '输入 1/2/3: '; read -r c
        case "$c" in
            1) SCENARIO=agg ;; 2) SCENARIO=cell1 ;; 3) SCENARIO=cell2 ;;
            *) echo "无效选择" >&2; exit 1 ;;
        esac
    fi
    case "$SCENARIO" in agg|cell1|cell2) ;; *) echo "SCENARIO 须为 agg|cell1|cell2" >&2; exit 1 ;; esac
    [ "$ASSUME_YES" = "1" ] && return 0
    local desc="聚合开启(双蜂窝)"
    [ "$SCENARIO" = "cell1" ] && desc="仅蜂窝1"
    [ "$SCENARIO" = "cell2" ] && desc="仅蜂窝2"
    printf '>>> 请确认 WEB 上已配置为【%s】，回车继续（Ctrl-C 取消）' "$desc"
    read -r _
}

# ── SSH（密码置空走免密 key；填了则用 sshpass 自动登录） ──
GW_OK=0
SSH_BASE="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
gw() {
    if [ -n "$GW_PASS" ]; then sshpass -p "$GW_PASS" ssh $SSH_BASE "$GW_SSH" "$@"
    else ssh -o BatchMode=yes $SSH_BASE "$GW_SSH" "$@"; fi
}

check_deps() {
    local ok=0
    for d in iperf3 python3 ssh ping awk; do
        command -v "$d" >/dev/null 2>&1 || { echo "error: PC 缺少 $d" >&2; ok=1; }
    done
    if [ -n "$GW_PASS" ] && ! command -v sshpass >/dev/null 2>&1; then
        echo "error: 使用密码登录需安装 sshpass（apt install sshpass）" >&2; ok=1
    fi
    # 预检：test server 的 iperf3 端口是否可达（你在 ts 上手动起的服务端）
    [ "$MODE" != "latency" ] && { 
        if ! timeout 3 bash -c "</dev/tcp/$TEST_TARGET/$IPERF_PORT" 2>/dev/null; then
	   echo "error: $TEST_TARGET:$IPERF_PORT 不可达——请先在 ts 上运行: iperf3 -s -p $IPERF_PORT" >&2
	   ok=1
	fi
    }
    if [ -z "$GW_SSH" ]; then
        log "GW_SSH 未配置：跳过路径验证（状态标 UNVERIFIED）"
    elif gw "true" 2>/dev/null; then GW_OK=1
    else log "warn: GW 不可 SSH，将跳过路径验证（状态标 UNVERIFIED）"; fi
    return $ok
}

gw_if_bytes() { gw "cat /sys/class/net/$1/statistics/rx_bytes /sys/class/net/$1/statistics/tx_bytes 2>/dev/null" \
    | awk 'NR==1{r=$1} NR==2{t=$1} END{printf "%.0f\n", r+t}'; }
    # 必须 printf "%.0f"：print 在大数时会输出科学计数法(7.07e+09)，bash 算术无法解析

# 路径验证：场景声明 vs GW 接口实际字节增量
verify_path() { # $1=da $2=db → OK|1PATH|WRONGPATH|UNVERIFIED
    [ "$GW_OK" = "1" ] || { echo "UNVERIFIED"; return; }
    local da="$1" db="$2" tot=$(( $1 + $2 ))
    [ "$tot" -le 0 ] && { echo "UNVERIFIED"; return; }
    case "$SCENARIO" in
        agg)   awk -v a="$da" -v b="$db" -v t="$tot" 'BEGIN{m=(a<b?a:b); exit !(m<0.05*t)}' \
                 && echo "1PATH" || echo "OK" ;;    # 双链路都应 ≥5%
        cell1) awk -v k="$da" -v t="$tot" 'BEGIN{exit !(k<0.95*t)}' \
                 && echo "WRONGPATH" || echo "OK" ;; # 应 ≥95% 在链路1
        cell2) awk -v k="$db" -v t="$tot" 'BEGIN{exit !(k<0.95*t)}' \
                 && echo "WRONGPATH" || echo "OK" ;;
    esac
}

# ── iperf（服务端由你在 ts 上手动常驻，脚本只跑客户端） ─────
run_iperf() { # $1=P $2=dir(up|down) $3=duration → "bw_mbps retrans"
    local P="$1" dir="$2" dur="$3" extra=""
    [ "$dir" = "down" ] && extra="-R"
    local json; json="$(mktemp)"
    timeout $((dur + 20)) iperf3 -c "$TEST_TARGET" -p "$IPERF_PORT" \
        -t "$dur" -O "$WARMUP" -P "$P" $extra --json >"$json" 2>/dev/null || true
    python3 - "$json" <<'EOF'
import json, sys
try:
    e = json.load(open(sys.argv[1])).get("end", {})
    s = e.get("sum_received") or e.get("sum_sent") or {}
    rt = (e.get("sum_sent") or {}).get("retransmits", 0)
    print(f"{s.get('bits_per_second',0)/1e6:.1f} {rt}")
except Exception:
    print("0.0 0")
EOF
    rm -f "$json"
}

# ═══════════════ 吞吐 ═══════════════
bench_tput() {
    local n_dir n_P runs
    n_dir=$(wc -w <<<"$DIRECTIONS"); n_P=$(wc -w <<<"$PVALUES")
    runs=$(( n_dir * n_P * REPEAT ))
    log "═══ 吞吐测试：scenario=$SCENARIO，共 $runs 次 × ${DURATION}s ≈ $(( runs * DURATION / 60 + 1 )) 分钟 ═══"
    local dir P rep
    for dir in $DIRECTIONS; do
        for P in $PVALUES; do
            for rep in $(seq 1 "$REPEAT"); do
                printf '  %-5s %-4s P=%-2s rep %d/%d ... ' "$SCENARIO" "$dir" "$P" "$rep" "$REPEAT"
                local a0=0 b0=0 a1=0 b1=0 bw rt status
                [ "$GW_OK" = "1" ] && { a0="$(gw_if_bytes "$GW_IF_A")"; b0="$(gw_if_bytes "$GW_IF_B")"; }
                read -r bw rt <<<"$(run_iperf "$P" "$dir" "$DURATION")"
                [ "$GW_OK" = "1" ] && { a1="$(gw_if_bytes "$GW_IF_A")"; b1="$(gw_if_bytes "$GW_IF_B")"; }
                local da=$(( ${a1:-0} - ${a0:-0} )) db=$(( ${b1:-0} - ${b0:-0} ))

                if ! awk -v b="$bw" 'BEGIN{exit !(b+0>0)}'; then status="ZERO_BW"
                else status="$(verify_path "$da" "$db")"; fi
                echo "$bw Mbps retx=$rt pathA=${da}B pathB=${db}B [$status]"
                echo "$SCENARIO,$dir,$P,$rep,$bw,$rt,$da,$db,$status" >>"$CSV_TPUT"
            done
        done
    done
    log "完成 → $CSV_TPUT"
}

# ═══════════════ 延迟/抖动/丢包 ═══════════════
bench_latency() {
    log "═══ 延迟测试：PC → $TEST_TARGET（$PING_COUNT 次） ═══"
    ping -c "$PING_COUNT" -i 0.2 -W 1 -q "$TEST_TARGET" 2>/dev/null \
      | awk -v ts="$(date +%s)" -v sc="$SCENARIO" '
          /packets transmitted/{sent=$1; loss=$(NF-4); sub(/%/,"",loss)}
          /min\/avg/{split($0,a,"= "); split(a[2],b,"/");
                     printf "%s,%s,%d,%s,%.2f,%.2f,%.2f\n", sc, ts, sent, loss, b[2], b[3], b[4]}
          ' >>"$CSV_LAT"
    tail -1 "$CSV_LAT"
    log "完成 → $CSV_LAT"
}

# ═══════════════ 故障切换（仅 agg，手动断链） ═══════════════
bench_failover() {
    [ "$SCENARIO" = "agg" ] || { log "skip: failover 只在 SCENARIO=agg 下有意义"; return; }
    local rate_opt=""
    [ -n "$FO_BITRATE" ] && rate_opt="-b $FO_BITRATE"
    log "═══ failover：总 ${FO_DURATION}s（${FO_DOWN_AT}s 断一路、${FO_UP_AT}s 恢复）${FO_BITRATE:+，限速 $FO_BITRATE} ═══"
    local pinglog="$RESULTS_DIR/fo_ping_$(date +%s).log" iperfjson="$RESULTS_DIR/fo_iperf.json"
    ping -D -i 0.2 -W 1 "$TEST_TARGET" >"$pinglog" 2>/dev/null &
    local pingpid=$!
    timeout $((FO_DURATION + 20)) iperf3 -c "$TEST_TARGET" -p "$IPERF_PORT" \
        -t "$FO_DURATION" -i 1 -P 4 $rate_opt --json >"$iperfjson" 2>/dev/null &
    local ipid=$!

    sleep "$FO_DOWN_AT"
    echo ""; echo ">>> 【现在】请在 WEB 上关闭一路蜂窝（断链测试），操作无需回车，脚本自动计时"
    sleep $(( FO_UP_AT - FO_DOWN_AT ))
    echo ""; echo ">>> 【现在】请在 WEB 上恢复该蜂窝"
    sleep $(( FO_DURATION - FO_UP_AT ))
    wait "$ipid" 2>/dev/null || true
    kill "$pingpid" 2>/dev/null || true; wait "$pingpid" 2>/dev/null || true

    python3 - "$pinglog" "$iperfjson" "$FO_DOWN_AT" "$FO_RECOVER_PCT" "$CSV_FO" "$SCENARIO" <<'EOF'
import json, re, sys
pinglog, iperfjson, down_at, rec_pct, csv, sc = \
    sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), sys.argv[5], sys.argv[6]
# ping：icmp_seq 缺口 → 丢包数；-D 时间戳 → 最长连续中断窗口
seqs, tmap = [], {}
for line in open(pinglog):
    m = re.match(r'\[(\d+\.\d+)\].*icmp_seq=(\d+)', line)
    if m: seqs.append(int(m.group(2))); tmap[int(m.group(2))] = float(m.group(1))
lost, maxgap = 0, 0.0
for i in range(1, len(seqs)):
    gap = seqs[i] - seqs[i-1] - 1
    if gap > 0:
        lost += gap
        maxgap = max(maxgap, tmap[seqs[i]] - tmap[seqs[i-1]])
# iperf：找吞吐凹陷段（不依赖你手工操作的精确时刻）
dip, recover, dipped = 0.0, -1.0, False
try:
    iv = json.load(open(iperfjson))["intervals"]
    tp = [(s["sum"]["start"], s["sum"]["bits_per_second"]/1e6) for s in iv]
    pre = [v for t, v in tp if t < down_at - 2]
    if pre:
        base = sum(pre)/len(pre)
        post = [(t, v) for t, v in tp if t >= down_at]
        if post and base > 0:
            dip = (1 - min(v for _, v in post)/base) * 100
            for t, v in post:
                if v < base*0.5: dipped = True           # 先检测到明显凹陷
                elif dipped and v >= base*rec_pct/100:   # 再恢复到阈值
                    recover = t - down_at + 1; break
except Exception:
    pass
# 状态判定（覆盖无缝/近无缝场景）：
#   OK            有凹陷且已恢复（正常切换）
#   NO_LOSS       零丢包零凹陷（完全无缝）
#   NEAR_SEAMLESS 吞吐无凹陷但有零星丢包（近无缝，恢复时间无意义，看丢包和中断窗口）
#   NO_RECOVER    有凹陷但测试窗口内未恢复（切换有问题）
if recover >= 0:   status = "OK"
elif not dipped:   status = "NO_LOSS" if lost == 0 else "NEAR_SEAMLESS"
else:              status = "NO_RECOVER"
print(f"  丢包={lost} 最长中断={maxgap:.1f}s 吞吐跌落={dip:.0f}% 恢复={recover:.0f}s [{status}]")
open(csv, "a").write(f"{sc},{lost},{maxgap:.1f},{dip:.0f},{recover:.0f},{status}\n")
EOF
    log "完成 → $CSV_FO"
}

# ═══════════════ 汇总（合并 agg/cell1/cell2 三次结果） ═══════════════
summary() {
    python3 - "$CSV_TPUT" <<'EOF'
import csv, sys, collections
d = collections.defaultdict(list)
st = collections.Counter()
for r in csv.DictReader(open(sys.argv[1])):
    if r["scenario"] in ("agg", "cell1", "cell2"):
        st[r["status"]] += 1
        if r["status"] in ("OK", "UNVERIFIED"):
            d[(r["scenario"], r["direction"], r["P"])].append(float(r["bw_mbps"]))
def m(k): v = d.get(k); return sum(v)/len(v) if v else 0
cells = {(dr, P) for (_, dr, P) in d}
if not cells:
    print("（无有效样本，请先跑 SCENARIO=agg/cell1/cell2 MODE=tput）"); sys.exit(0)
print(f" {'dir':<5} {'P':>2} {'cell1':>8} {'cell2':>8} {'agg':>8} {'增益%':>7} {'聚合率%':>8}")
print(" " + "-"*55)
for dr, P in sorted(cells, key=lambda k: (k[0], int(k[1]))):
    a, b, du = m(("cell1", dr, P)), m(("cell2", dr, P)), m(("agg", dr, P))
    base = max(a, b)
    gain = f"{(du/base-1)*100:+.0f}%" if base > 0 and du > 0 else "-"
    eff  = f"{du/(a+b)*100:.0f}%" if (a+b) > 0 and du > 0 else "-"
    print(f" {dr:<5} {P:>2} {a:>8.1f} {b:>8.1f} {du:>8.1f} {gain:>7} {eff:>8}")
print(f"""
增益%  = agg / max(cell1, cell2)  —— 相对最强单链路的提升
聚合率% = agg / (cell1 + cell2)   —— 占两链路之和的比例（100% 为理想）
样本状态统计: {dict(st)}（1PATH/WRONGPATH/ZERO_BW 已排除；UNVERIFIED 计入但未经验证）""")
EOF
}

main() {
    echo "================================================================"
    echo " MPTCP test  $(date '+%F %T')   PC -> GW -> VPS -> $TEST_TARGET"
    echo "================================================================"
    pick_mode
    [ "$MODE" = "summary" ] && { summary; exit 0; }
    pick_scenario
    echo " SCENARIO=$SCENARIO MODE=$MODE DIR={$DIRECTIONS} P={$PVALUES} REPEAT=$REPEAT DURATION=${DURATION}s"
    echo " Results: $RESULTS_DIR"
    check_deps || exit 1
    case "$MODE" in
        tput)     bench_tput ;;
        latency)  bench_latency ;;
        failover) bench_failover ;;
        all)      bench_tput; bench_latency; [ "$SCENARIO" = "agg" ] && bench_failover ;;
        *) echo "未知 MODE=$MODE" >&2; exit 1 ;;
    esac
    summary
}
main "$@"
