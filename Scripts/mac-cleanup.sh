#!/bin/bash
# ============================================================
#  mac-cleanup.sh —— macOS 磁盘空间清理脚本
#
#  默认只"预览"（统计能释放多少空间，不删任何文件），
#  加 --clean 才会真正删除，且删除前会再次要求确认。
#
#  只清理可再生的东西：缓存 / 日志 / 构建产物 / 废纸篓。
#  永不触碰：文档、照片、源码、聊天记录、账号、设置、插件。
#
#  【软件不写死】每次运行都会扫描 /Applications 与 ~/Applications 里
#  装了哪些软件，再扫这些软件在 ~/Library 下的数据目录，
#  只清理"名字就是缓存/日志"的子目录（Cache、Caches、CacheStorage、
#  Service Worker 缓存、GPUCache、*_cache、log、Crashpad/completed …）。
#  数据库、聊天记录、设置、账号、插件目录不在白名单里，永远不动。
#
#  常用命令：
#    ./mac-cleanup.sh               # 先预览
#    ./mac-cleanup.sh --clean       # 一条命令全部清理
#    ./mac-cleanup.sh --clean -y    # 不再确认
#    ./mac-cleanup.sh --clean --downloads
#    ./mac-cleanup.sh --report      # 找出主目录里的"空间大户"
#
#  除通用扫描外，Docker 单独处理：镜像/容器/卷要调 docker 命令才清得掉。
# ============================================================

set -u
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

MODE="preview"; ASSUME_YES=0
CLEAN_APPS=1; CLEAN_DOCKER=1; CLEAN_DOCKER_ALL=0
CLEAN_DOWNLOADS=0; DOWNLOADS_DAYS=90; REPORT_HOME=0
CLEANING=0; TOTAL_KB=0
SCAN_TOP="${SCAN_TOP:-12}"     # 预览里列多少个软件，可用 SCAN_TOP=30 ./mac-cleanup.sh 调整

usage() {
  cat <<'EOF'
用法: ./mac-cleanup.sh [选项]
  (默认)        预览：只统计能释放多少空间，不删除任何文件
  --clean       执行真实清理（会先展示清单并要求确认）
  -y, --yes     配合 --clean，跳过确认

  --clean 默认会做：
    · 常规缓存 / 日志 / 开发工具缓存 / 废纸篓
    · 扫描所有已安装软件，清理它们各自的缓存与日志
    · Docker 未使用镜像 / 停止的容器 / 构建缓存

  按软件跳过（软件清单是自动扫出来的，不用登记）：
  --no-apps     跳过"已安装软件缓存扫描"
  --no-wechat / --no-chrome / --no-wps   旧参数，等价于 --no-apps（兼容老版本菜单栏）
  --no-docker   跳过 Docker
  --docker-all  连"未被任何容器使用的 Docker 镜像"也删掉（下次要重新 pull/build）

  --downloads   顺带把「下载」文件夹里超过 90 天的旧文件移入废纸篓（可恢复）
  --report      额外列出主目录中占空间最大的文件夹、本地 Time Machine 快照
  -h, --help    显示本帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --clean)       MODE="clean" ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --apps)        CLEAN_APPS=1 ;;
    --no-apps)     CLEAN_APPS=0 ;;
    # 兼容旧版菜单栏传的参数（那时是分开的微信/Chrome/WPS 段）
    --no-wechat|--no-chrome|--no-wps) CLEAN_APPS=0 ;;
    --docker)      CLEAN_DOCKER=1 ;;
    --no-docker)   CLEAN_DOCKER=0 ;;
    --docker-all)  CLEAN_DOCKER=1; CLEAN_DOCKER_ALL=1 ;;
    --downloads)   CLEAN_DOWNLOADS=1 ;;
    --report)      REPORT_HOME=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) printf '未知参数: %s（见 --help）\n' "$arg"; exit 1 ;;
  esac
done

# ---------- 安全检查 ----------
if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 请不要用 sudo 运行：本脚本只清理当前用户（$USER）可再生的文件。" >&2
  exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ 本脚本面向 macOS，当前系统是 $(uname -s)。" >&2
  exit 1
fi

if [ -t 1 ]; then BOLD=$'\e[1m'; GREEN=$'\e[32m'; RESET=$'\e[0m'
else BOLD=''; GREEN=''; RESET=''; fi

# 扫描用的临时文件（退出时清掉）
APP_MAP=$(mktemp) || exit 1
SCAN_RAW=$(mktemp) || exit 1
SCAN_DIRS=$(mktemp) || exit 1
SCAN_ROWS=$(mktemp) || exit 1
SCAN_STATS=$(mktemp) || exit 1
trap 'rm -f "$APP_MAP" "$SCAN_RAW" "$SCAN_DIRS" "$SCAN_ROWS" "$SCAN_STATS"' EXIT
trap 'exit 130' INT TERM

size_kb()  { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }
disk_free(){ df -k / | awk 'NR==2{print $4}'; }
human()    { awk -v kb="${1:-0}" 'BEGIN{split("KB MB GB TB",u," ");s=kb;i=1;
              while(s>=1024&&i<4){s/=1024;i++}printf "%.1f %s",s,u[i]}'; }
running()  { pgrep -x "$1" >/dev/null 2>&1; }

# num_kb "1.2GB" / "512kB" / "114B" → KB（用于解析 docker 自己报告的大小）
num_kb() {
  awk -v v="${1:-0}" 'BEGIN{
    gsub(/\(.*/, "", v); gsub(/[ \t]/, "", v)
    n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
    m = 0.001
    if (u == "kB" || u == "KB" || u == "kb" || u == "K") m = 1
    else if (u == "MB") m = 1024
    else if (u == "GB") m = 1048576
    else if (u == "TB") m = 1073741824
    printf "%d", n * m
  }'
}

# clean_path "说明" "目录或文件"：目录 → 清空内容但保留目录本身；文件 → 直接删除
clean_path() {
  local label="$1" p="$2" kb
  [ -n "$p" ] || return 0
  [ -d "$p" ] || [ -f "$p" ] || return 0
  kb=$(size_kb "$p")
  [ "${kb:-0}" -ge 1024 ] || return 0          # 小于 1MB 的跳过，减少噪音
  if [ "$CLEANING" -eq 1 ]; then
    if [ -d "$p" ]; then find "$p" -mindepth 1 -delete 2>/dev/null
    else rm -f "$p" 2>/dev/null; fi
    printf '   ✓ %s  ——  已清理 %s\n' "$label" "$(human "$kb")"
  else
    printf '   · %s  ——  约 %s\n' "$label" "$(human "$kb")"
  fi
  TOTAL_KB=$((TOTAL_KB + kb))
}
clean_dir() { clean_path "$@"; }

# run_tool "说明" 命令...：包装"会自动重建缓存"的官方清理命令
run_tool() {
  local label="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 0
  if [ "$CLEANING" -eq 1 ]; then
    if "$@" >/dev/null 2>&1; then printf '   ✓ %s\n' "$label"
    else printf '   - %s（跳过）\n' "$label"; fi
  else
    printf '   · %s\n' "$label"
  fi
}

# ---------- 通用应用扫描 ----------
# 1) 从 /Applications 读出每个软件的 CFBundleIdentifier，用软件名标注来源
# 2) 扫 ~/Library/Containers/*/Data 与 ~/Library/Application Support/*
# 3) 只认"缓存/日志目录名白名单"，别的一律不碰

build_app_map() {
  local app id nm
  : >"$APP_MAP"
  for app in /Applications/*.app "$HOME"/Applications/*.app; do
    [ -d "$app" ] || continue
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || continue
    [ -n "$id" ] || continue
    # 优先用软件自己声明的显示名（"微信"），没有才退回文件名（"WeChat"）
    nm=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist" 2>/dev/null) || nm=""
    [ -n "${nm:-}" ] || nm=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist" 2>/dev/null) || nm=""
    [ -n "${nm:-}" ] || nm=$(basename "$app" .app)
    printf '%s\t%s\n' "$id" "$nm" >>"$APP_MAP"
  done
}

scan_app_caches() {
  # 这些目录整棵跳过：聊天记录（用户内容）、iPhone 备份（又慢又不是缓存）、
  # 图库包，以及交给 Docker 段单独处理的容器
  local prune=(
    -name xwechat_files
    -o -name MobileSync
    -o -name '*.photoslibrary'
    -o -path "$HOME/Library/Containers/com.docker.docker"
  )
  # 只有名字命中的目录才会被当作缓存；用户数据目录名都不在这个表里
  local names=(
    -iname cache -o -iname caches -o -iname 'code cache' -o -iname gpucache
    -o -iname dawncache -o -iname dawnwebgpucache -o -iname dawngraphitecache
    -o -iname graphitedawncache -o -iname shadercache -o -iname grshadercache
    -o -iname 'service worker' -o -iname 'shared dictionary'
    -o -iname 'application cache' -o -iname 'media cache'
    -o -iname crashpad -o -iname log -o -iname logs -o -iname '*_cache'
  )
  {
    find "$HOME/Library/Application Support" -maxdepth 8 -type d \
      \( \( "${prune[@]}" \) -prune \) -o -type d \( "${names[@]}" \) -print0 2>/dev/null
    find "$HOME/Library/Containers" -maxdepth 9 -type d \
      \( \( "${prune[@]}" \) -prune \) -o -type d \( "${names[@]}" \) -print0 2>/dev/null
  } >"$SCAN_RAW"

  # 去掉被父目录覆盖的子目录（父已整体清理，子再算一次就重复了），
  # 再把"只该清一部分"的目录换成真正的目标子目录：
  #   Service Worker → CacheStorage / ScriptCache（Database 里是站点状态，留着）
  #   Crashpad       → completed（new / pending 里是还没上报的转储，留着）
  tr '\0' '\n' <"$SCAN_RAW" | LC_ALL=C sort | awk '
    { for (i = 1; i <= k; i++) if (index($0, kept[i] "/") == 1) next
      k++; kept[k] = $0
      p = $0; b = p; sub(/.*\//, "", b); lb = tolower(b)
      if (lb == "service worker") { print p "/CacheStorage"; print p "/ScriptCache" }
      else if (lb == "crashpad")  { print p "/completed" }
      else                        { print p } }' >"$SCAN_DIRS"
}

# 目标目录都是纯缓存：清空内容、保留目录本身（应用会重建）
scan_clean() { find "$1" -mindepth 1 -delete 2>/dev/null; }

do_apps() {
  local apps n=0 total i=0 rest_kb=0 rest_n=0 k c l

  printf '   正在扫描已安装软件（20~30 秒）……\n'
  build_app_map
  apps=$(wc -l <"$APP_MAP" | tr -d ' ')
  scan_app_caches

  # 并行量体积：一次 du 一批，避免两千多个进程启动开销
  if [ -s "$SCAN_DIRS" ]; then
    tr '\n' '\0' <"$SCAN_DIRS" | xargs -0 -P 8 -n 25 du -sk 2>/dev/null >"$SCAN_RAW"
  else
    : >"$SCAN_RAW"
  fi

  # 挂上"这堆缓存属于哪个软件"，顺手过滤掉 <1MB 的
  awk -F'\t' -v OFS='\t' '
    NR == FNR { name[$1] = $2; next }
    {
      kb = $1 + 0
      if (kb < 1024) next
      p = $2; m = split(p, seg, "/"); lab = ""
      for (i = 1; i < m; i++)
        if (seg[i] == "Containers" && seg[i + 1] != "") {
          id = seg[i + 1]; lab = (id in name) ? name[id] : id; break
        }
      if (lab == "")
        for (i = 1; i < m; i++)
          if (seg[i] == "Application Support" && seg[i + 1] != "") { lab = seg[i + 1]; break }
      if (lab == "") lab = "其他"
      print kb, lab, p
    }' "$APP_MAP" "$SCAN_RAW" >"$SCAN_ROWS"

  n=$(wc -l <"$SCAN_ROWS" | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "   - 没扫到可清理的应用缓存（已装软件 ${apps} 个）"
    return 0
  fi

  if [ "$CLEANING" -eq 1 ]; then
    while IFS=$'\t' read -r k c l; do
      scan_clean "$l"
    done <"$SCAN_ROWS"
  fi

  awk -F'\t' '{ s[$2] += $1; c[$2]++ }
    END { for (l in s) printf "%s\t%d\t%s\n", s[l], c[l], l }' "$SCAN_ROWS" \
    | sort -rn >"$SCAN_STATS"

  total=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$SCAN_STATS")
  TOTAL_KB=$((TOTAL_KB + total))

  if [ "$CLEANING" -eq 1 ]; then
    printf '   ✓ 共清理 %s 处缓存，释放 %s（已装软件 %s 个）\n' "$n" "$(human "$total")" "$apps"
  else
    printf '   · 共 %s 处缓存，约 %s（已装软件 %s 个）\n' "$n" "$(human "$total")" "$apps"
  fi

  while IFS=$'\t' read -r k c l; do
    [ -n "${l:-}" ] || continue
    i=$((i+1))
    if [ "$i" -le "$SCAN_TOP" ]; then
      printf '     · %s —— %s（%s 处）\n' "$l" "$(human "$k")" "$c"
    else
      rest_kb=$((rest_kb + k)); rest_n=$((rest_n + c))
    fi
  done <"$SCAN_STATS"
  [ "$rest_n" -gt 0 ] && printf '     · 其余 %s 个软件 —— %s（%s 处）\n' "$((i - SCAN_TOP))" "$(human "$rest_kb")" "$rest_n"

  echo '     （用户数据：聊天记录 / 数据库 / 设置 / 账号 / 插件 都不在清理范围内）'
  return 0
}

do_downloads() {
  local dl="$HOME/Downloads" days="$DOWNLOADS_DAYS" tmp n kb dest f i=0
  [ -d "$dl" ] || return 0
  tmp=$(mktemp) || return 0
  find "$dl" -mindepth 1 -maxdepth 1 -mtime +"$days" -print0 2>/dev/null >"$tmp"
  n=$(tr -cd '\0' <"$tmp" | wc -c); n=$((n))
  if [ "$n" -eq 0 ]; then echo "   - 「下载」没有超过 ${days} 天的旧文件"; rm -f "$tmp"; return 0; fi
  kb=$(( $(xargs -0 stat -f%z <"$tmp" 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}') ))
  if [ "$CLEANING" -eq 1 ]; then
    dest="$HOME/.Trash/cleanup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest"
    while IFS= read -r -d '' f; do mv -f "$f" "$dest/" 2>/dev/null; done <"$tmp"
    printf '   ✓ 「下载」%s 个超过 %s 天的旧文件（%s）已移入废纸篓，可随时找回\n' "$n" "$days" "$(human "$kb")"
  else
    printf '   · 「下载」%s 个超过 %s 天的旧文件，共 %s（只会移入废纸篓，可恢复）\n' "$n" "$days" "$(human "$kb")"
    while IFS= read -r -d '' f; do
      [ "$i" -lt 5 ] && printf '      - %s\n' "$(basename "$f")"
      i=$((i+1))
    done <"$tmp"
    [ "$n" -gt 5 ] && printf '      ……等共 %s 项\n' "$n"
  fi
  TOTAL_KB=$((TOTAL_KB + kb))
  rm -f "$tmp"
}

# ---------- Docker ----------
docker_up() { docker info >/dev/null 2>&1; }

# docker_prune "说明" 命令...：执行 docker 清理，并按它自己报告的 "Total reclaimed space" 计数
docker_prune() {
  local label="$1"; shift
  local out reclaimed kb
  if [ "$CLEANING" -eq 1 ]; then
    out=$("$@" 2>&1)
    reclaimed=$(printf '%s\n' "$out" | sed -n 's/.*[Tt]otal reclaimed space:[[:space:]]*//p' | tail -n 1)
    if [ -n "$reclaimed" ]; then
      kb=$(num_kb "$reclaimed")
      if [ "${kb:-0}" -lt 1 ]; then
        printf '   - %s（本来就没什么可清）\n' "$label"
      else
        TOTAL_KB=$((TOTAL_KB + kb))
        printf '   ✓ %s —— 释放 %s\n' "$label" "$(human "$kb")"
      fi
    else
      printf '   - %s（没有可清理的内容）\n' "$label"
    fi
  else
    printf '   · %s\n' "$label"
  fi
}

do_docker() {
  local type size rec reclaim_kb=0 vol_kb=0 img_kb=0 up=0

  if ! command -v docker >/dev/null 2>&1; then
    echo "   - 没找到 docker 命令（Docker Desktop 未安装，或 PATH 里没有），只清主机侧缓存"
  elif ! docker_up; then
    echo "   - Docker 没在运行，跳过镜像/容器清理（打开 Docker Desktop 后再跑一次）；"
    echo "     主机侧的日志和缓存仍然会清理 ↓"
  else
    up=1
    echo "   ${BOLD}当前 Docker 占用${RESET}"
    while IFS='|' read -r type size rec; do
      [ -n "$type" ] || continue
      printf '     %-14s 占用 %-9s 可回收 %s\n' "$type" "$size" "$rec"
    done <<<"$(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)"

    # 可回收量：数据卷脚本不删；镜像分两种——默认 prune 只删"悬空镜像"，
    # 全部未使用镜像要 --docker-all 才删，所以不加到默认估算里，避免虚报。
    while IFS='|' read -r type _ rec; do
      [ -n "$type" ] || continue
      case "$type" in
        "Local Volumes") vol_kb=$(num_kb "$rec") ;;
        "Images")
          img_kb=$(num_kb "$rec")
          [ "$CLEAN_DOCKER_ALL" -eq 1 ] && reclaim_kb=$((reclaim_kb + img_kb)) ;;
        *) reclaim_kb=$((reclaim_kb + $(num_kb "$rec"))) ;;
      esac
    done <<<"$(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)"
  fi

  if [ "$up" -eq 1 ]; then
    docker_prune "docker system prune -f（悬空镜像 / 停止的容器 / 无用网络 / 构建缓存）" docker system prune -f
    docker_prune "docker builder prune -f（构建缓存）" docker builder prune -f
    if [ "$CLEANING" -ne 1 ]; then
      if [ "${reclaim_kb:-0}" -lt 1024 ]; then
        printf '   - 默认 prune 这次没什么可删（悬空镜像 / 停止容器 / 构建缓存都是空的）\n'
      else
        printf '   · 上述 prune 最多可回收约 %s（悬空镜像/停止容器/构建缓存合计）\n' "$(human "$reclaim_kb")"
      fi
      TOTAL_KB=$((TOTAL_KB + reclaim_kb))
    fi
    if [ "${vol_kb:-0}" -ge 1024 ]; then
      printf '   - 另有未使用的数据卷 %s，脚本不动它（里面可能是数据库！）\n' "$(human "$vol_kb")"
      echo "     确认某个卷是垃圾后再: docker volume rm <卷名>（或 docker volume prune -f 一次删光未使用卷）"
    fi
    if [ "${img_kb:-0}" -ge 1048576 ] && [ "$CLEAN_DOCKER_ALL" -ne 1 ]; then
      printf '   - 其中约 %s 是"没被任何容器使用的镜像"，要删得加 --docker-all（下次用需重新 pull/build）\n' "$(human "$img_kb")"
    fi
    if [ "$CLEAN_DOCKER_ALL" -eq 1 ]; then
      docker_prune "docker image prune -a -f（所有没被容器使用的镜像）" docker image prune -a -f
    fi
  fi

  clean_dir "Docker Desktop 日志"      "$HOME/Library/Containers/com.docker.docker/Data/log"
  clean_dir "Docker 进程采样 trace"    "$HOME/Library/Containers/com.docker.docker/Data/default.profraw"
  clean_dir "Docker Scout 漏洞库缓存"  "$HOME/.docker/scout"
  clean_dir "Docker SBOM 缓存"         "$HOME/.docker/sbom"

  # 只报告、不删除：这块是真正的"磁盘大户"
  local raw="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" kb
  if [ -f "$raw" ]; then
    kb=$(du -sk "$raw" 2>/dev/null | awk '{print $1+0}')
    [ "${kb:-0}" -ge 1048576 ] && printf '   - Docker 虚拟磁盘 Docker.raw 实占 %s（镜像/卷都在里面，只能靠上面 prune 变小，脚本不会删它）\n' "$(human "$kb")"
  fi
  return 0
}

do_cleanup() {
  local H="$HOME"

  echo "${BOLD}【废纸篓】${RESET}"
  clean_dir "废纸篓 ~/.Trash" "$H/.Trash"

  echo "${BOLD}【系统级应用缓存】（应用会自动重建，首次启动可能稍慢）${RESET}"
  clean_dir "用户缓存 ~/Library/Caches"          "$H/Library/Caches"
  if running Xcode; then
    echo "   - Xcode 正在运行，已跳过 DerivedData（退出 Xcode 后再清理）"
  else
    clean_dir "Xcode 构建缓存 DerivedData"       "$H/Library/Developer/Xcode/DerivedData"
    clean_dir "Xcode 设备支持文件"               "$H/Library/Developer/Xcode/iOS DeviceSupport"
  fi
  clean_dir "模拟器缓存"                          "$H/Library/Developer/CoreSimulator/Caches"

  echo "${BOLD}【日志】${RESET}"
  clean_dir "应用日志 ~/Library/Logs"             "$H/Library/Logs"

  echo "${BOLD}【开发工具缓存】（重新构建时会自动重新下载）${RESET}"
  clean_dir "npm 缓存"                            "$H/.npm/_cacache"
  clean_dir "yarn 缓存"                           "$H/.cache/yarn"
  clean_dir "Gradle 缓存"                         "$H/.gradle/caches"
  if command -v brew >/dev/null 2>&1; then
    clean_dir "Homebrew 下载缓存"                 "$(brew --cache 2>/dev/null)"
  fi
  run_tool "brew cleanup --prune=all（旧版本软件包）" brew cleanup --prune=all
  run_tool "pnpm store prune"                      pnpm store prune
  run_tool "go clean -modcache"                    go clean -modcache
  run_tool "删除已不可用的 iOS 模拟器"             xcrun simctl delete unavailable

  if [ "$CLEAN_APPS" -eq 1 ]; then
    echo "${BOLD}【已安装软件的缓存】（自动扫描，不是写死的清单）${RESET}"
    do_apps
  fi
  if [ "$CLEAN_DOCKER" -eq 1 ]; then
    echo "${BOLD}【Docker】${RESET}"
    do_docker
  fi
  if [ "$CLEAN_DOWNLOADS" -eq 1 ]; then
    echo "${BOLD}【下载文件夹整理】（--downloads）${RESET}"
    do_downloads
  fi
  return 0
}

# ---------- 主流程 ----------
BEFORE_KB=$(disk_free)
echo "系统盘当前剩余: ${GREEN}$(human "$BEFORE_KB")${RESET}"
echo
echo "${BOLD}====== 第 1 步 · 预览（不删除任何文件）======${RESET}"
do_cleanup
echo

if [ "$MODE" = "clean" ]; then
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '即将删除以上内容（约 %s），继续? [y/N] ' "$(human "$TOTAL_KB")"
    read -r answer
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "已取消，未删除任何文件。"; exit 0 ;;
    esac
  fi
  echo
  echo "${BOLD}====== 第 2 步 · 开始清理 ======${RESET}"
  CLEANING=1; TOTAL_KB=0
  do_cleanup
  AFTER_KB=$(disk_free)
  echo
  echo "${GREEN}✔ 本次共释放约 $(human "$TOTAL_KB")${RESET}"
  echo "系统盘剩余: $(human "$BEFORE_KB")  →  $(human "$AFTER_KB")"
  echo "$(date '+%Y-%m-%d %H:%M:%S')  freed=$(human "$TOTAL_KB")" >>"$HOME/.mac-cleanup.log" 2>/dev/null || true
else
  echo "${GREEN}预计可释放约 $(human "$TOTAL_KB")${RESET}"
  echo "确认后执行:  ./mac-cleanup.sh --clean            # 常规缓存 + 所有软件缓存 + Docker"
  echo "可选追加:  --downloads   把「下载」超过 ${DOWNLOADS_DAYS} 天的旧文件移入废纸篓"
  echo "          --docker-all  连未被使用的 Docker 镜像一起删（可多省几 GB）"
  echo "          --report      顺便列出主目录里的空间大户"
  echo "跳过某项:  --no-apps（跳过软件扫描） / --no-docker"
fi

if [ "$REPORT_HOME" -eq 1 ]; then
  echo
  echo "${BOLD}====== 空间大户排查（仅供参考，脚本不会动它们）======${RESET}"
  echo "正在扫描主目录，可能需要一两分钟……"
  du -xdk 1 "$HOME" 2>/dev/null | sort -rn | head -15 \
    | while read -r kb p; do printf '   %-10s %s\n' "$(human "$kb")" "$p"; done
  if command -v tmutil >/dev/null 2>&1; then
    echo
    echo "${BOLD}本地 Time Machine 快照（APFS 快照常悄悄占几十 GB）：${RESET}"
    tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/   /'
    echo "   删除某个快照: tmutil deletelocalsnapshots <快照日期>"
  fi
fi
