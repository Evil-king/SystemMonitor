#!/bin/bash
# ============================================================
#  mac-cleanup.sh —— macOS 磁盘空间清理脚本
#
#  默认只"预览"（统计能释放多少空间，不删任何文件），
#  加 --clean 才会真正删除，且删除前会再次要求确认。
#
#  只清理可再生的东西：缓存 / 日志 / 构建产物 / 废纸篓。
#  永不触碰：文档、照片、源码、聊天记录、Xcode Archives、系统文件。
#
#  默认一并清理 微信 / Chrome / WPS / Docker（这四段都只动缓存和日志），
#  加 --no-wechat / --no-chrome / --no-wps / --no-docker / --no-apps 可跳过。
#
#  常用命令：
#    ./mac-cleanup.sh               # 先预览（微信/Chrome/WPS/Docker 的占用也会列出来）
#    ./mac-cleanup.sh --clean       # 一条命令全部清理（含微信/Chrome/WPS/Docker）
#    ./mac-cleanup.sh --clean -y    # 不再确认
#    ./mac-cleanup.sh --clean --downloads
#    ./mac-cleanup.sh --report      # 找出主目录里的"空间大户"
#
#  四段的分寸：
#  · 微信：只删日志 + 小程序/网页的 Chromium Cache；Cookie、Local Storage、
#          IndexedDB 保留（小程序不掉登录），聊天记录 xwechat_files 一个字节不碰。
#  · Chrome：只删 Service Worker 缓存、GPU/着色器缓存、崩溃转储、组件下载缓存；
#          书签、历史、Cookie、密码、扩展、网站数据（IndexedDB/Local Storage）都不动。
#  · WPS：只删日志/临时文件/内嵌浏览器缓存/在线字体缓存；
#          文档自动备份(backup)、已装插件(addons)、已下载字体(extend_font) 都不动。
#  · Docker：只删悬空镜像/停止的容器/构建缓存/日志/Scout 库，
#          数据卷一律不动（里面常常装着数据库）；--docker-all 才连未使用镜像一起删。
# ============================================================

set -u
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

MODE="preview"; ASSUME_YES=0
CLEAN_WECHAT=1; CLEAN_CHROME=1; CLEAN_WPS=1; CLEAN_DOCKER=1; CLEAN_DOCKER_ALL=0
CLEAN_DOWNLOADS=0; DOWNLOADS_DAYS=90; REPORT_HOME=0
CLEANING=0; TOTAL_KB=0

usage() {
  cat <<'EOF'
用法: ./mac-cleanup.sh [选项]
  (默认)        预览：只统计能释放多少空间，不删除任何文件
  --clean       执行真实清理（会先展示清单并要求确认）
  -y, --yes     配合 --clean，跳过确认

  --clean 默认会连带清理 微信 / Chrome / WPS / Docker 的缓存与日志：
  --docker-all  连"未被任何容器使用的 Docker 镜像"也删掉（省更多，但下次要重新 pull/build）
  --no-wechat   这次跳过微信
  --no-chrome   这次跳过 Chrome
  --no-wps      这次跳过 WPS
  --no-docker   这次跳过 Docker
  --no-apps     以上四项都跳过（只清常规缓存）
  --docker / --wps  为兼容旧命令保留，现在本来就是默认行为

  --downloads   顺带把「下载」文件夹里超过 90 天的旧文件移入废纸篓（可恢复）
  --report      额外列出主目录中占空间最大的文件夹、本地 Time Machine 快照
  -h, --help    显示本帮助
EOF
}

for arg in "$@"; do
  case "$arg" in
    --clean)       MODE="clean" ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --docker)      CLEAN_DOCKER=1 ;;
    --no-docker)   CLEAN_DOCKER=0 ;;
    --docker-all)  CLEAN_DOCKER=1; CLEAN_DOCKER_ALL=1 ;;
    --wps)         CLEAN_WPS=1 ;;
    --no-wps)      CLEAN_WPS=0 ;;
    --wechat)      CLEAN_WECHAT=1 ;;
    --no-wechat)   CLEAN_WECHAT=0 ;;
    --chrome)      CLEAN_CHROME=1 ;;
    --no-chrome)   CLEAN_CHROME=0 ;;
    --no-apps)     CLEAN_WECHAT=0; CLEAN_CHROME=0; CLEAN_WPS=0; CLEAN_DOCKER=0 ;;
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

# ---------- 微信 ----------
# 微信 4.x 把聊天数据放在 Documents/xwechat_files/，小程序和公众号网页用 Chromium profile。
# 只清 log 和各 profile 里的 Cache 类目录：Cookie / Local Storage / IndexedDB 都留着，
# 所以小程序、网页不会掉登录；聊天记录、图片、文件一个字节都不碰。
wechat_running() { pgrep -f 'WeChat[0-9]*\.app/Contents/MacOS/WeChat' >/dev/null 2>&1; }

# 只有主容器才处理：com.tencent.xinWeChat、com.tencent.xinWeChat2、…3
# （.MiniProgram / .WeChatMacShare / .IPCHelper 这些子容器一律跳过）
wechat_main_container() {
  case "$(basename "$1")" in
    com.tencent.xinWeChat|com.tencent.xinWeChat[0-9]*) ;;
    *) return 1 ;;
  esac
  [ -d "$1/Data/Documents/app_data" ] || return 1
  return 0
}

# clean_webview_caches "说明" "<profiles 目录>"：只删各 profile 下的缓存子目录
clean_webview_caches() {
  local label="$1" profiles="$2" total=0 d kb
  local names=(-name Cache -o -name 'Code Cache' -o -name GPUCache -o -name DawnCache
               -o -name DawnWebGPUCache -o -name ShaderCache -o -name GrShaderCache)
  [ -d "$profiles" ] || return 0
  while IFS= read -r -d '' d; do
    kb=$(size_kb "$d"); total=$((total + ${kb:-0}))
  done < <(find "$profiles" -mindepth 2 -maxdepth 2 -type d \( "${names[@]}" \) -print0 2>/dev/null)
  [ "${total:-0}" -ge 1024 ] || return 0
  if [ "$CLEANING" -eq 1 ]; then
    find "$profiles" -mindepth 2 -maxdepth 2 -type d \( "${names[@]}" \) -exec rm -rf {} + 2>/dev/null
    printf '   ✓ %s  ——  已清理 %s\n' "$label" "$(human "$total")"
  else
    printf '   · %s  ——  约 %s\n' "$label" "$(human "$total")"
  fi
  TOTAL_KB=$((TOTAL_KB + total))
}

do_wechat() {
  local B R nm kb n=0
  # 主容器才有 Documents/app_data；MiniProgram、WeChatMacShare 这些子容器自动排除
  for B in "$HOME"/Library/Containers/com.tencent.xinWeChat*; do
    wechat_main_container "$B" && n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then
    echo "   - 没找到微信用户数据（未安装，或从未启动过）"
    return 0
  fi
  if wechat_running; then
    echo "   - 微信正在运行：日志和 Cache 照样能清，但退出微信后再跑一次会清得更干净"
  fi

  for B in "$HOME"/Library/Containers/com.tencent.xinWeChat*; do
    wechat_main_container "$B" || continue
    R="$B/Data"
    nm="微信"
    case "$B" in *xinWeChat2) nm="微信 2" ;; *xinWeChat3) nm="微信 3" ;; esac
    [ "$n" -gt 1 ] && printf '   %s（%s）\n' "$nm" "$(basename "$B")"

    clean_dir "运行日志 app_data/log"                  "$R/Documents/app_data/log"
    clean_webview_caches "小程序/网页缓存（只删 Cache，保留登录态）" "$R/Documents/app_data/radium/web/profiles"
    clean_dir "小程序运行缓存 radium/cache"            "$R/Documents/app_data/radium/cache"
    clean_dir "插件运行缓存 xplugin"                   "$R/Documents/app_data/xplugin"
    clean_dir "崩溃记录 crashinfo"                     "$R/Documents/app_data/crashinfo"
    clean_dir "缓存目录 cacheDir"                      "$R/Documents/cacheDir"
    clean_dir "上报插件缓存 TPReportPluginCache"       "$R/Documents/TPReportPluginCache"
    clean_dir "微信缓存 Library/Caches"                "$R/Library/Caches"

    kb=$(size_kb "$R/Documents/xwechat_files")
    [ "${kb:-0}" -ge 102400 ] && printf '   - 聊天记录/图片/文件 xwechat_files/ —— %s（绝不自动删；要清进微信「设置 → 通用 → 存储空间」）\n' "$(human "$kb")"
    kb=$(size_kb "$R/Documents/app_data/radium/users")
    [ "${kb:-0}" -ge 102400 ] && printf '   - 小程序用户数据 radium/users/ —— %s（删了小程序要重新登录，故保留）\n' "$(human "$kb")"
  done
  return 0
}

# ---------- Chrome ----------
# 只清缓存类目录：Service Worker 缓存、GPU/着色器缓存、崩溃转储、组件下载缓存。
# 书签 / 历史 / Cookie / 密码 / 扩展 / 网站数据（IndexedDB、Local Storage）一律不动，
# 所以清完不会掉登录、不会丢书签，只是网页下次要重新下载资源。
chrome_running() { pgrep -x "Google Chrome" >/dev/null 2>&1; }

do_chrome() {
  local C="$HOME/Library/Application Support/Google/Chrome" P kb ext_kb=0 n=0

  if [ ! -d "$C" ]; then
    echo "   - 没找到 Chrome 用户数据（未安装，或从未启动过 Google Chrome）"
    return 0
  fi

  # 用户 profile：Default、Profile 1、Profile 2…
  # （Chrome 内部的 System Profile 缓存通常不到几 MB，忽略不值得，避免输出里出现没内容的标题）
  for P in "$C"/Default "$C"/"Profile "*; do
    [ -d "$P" ] && n=$((n+1))
  done

  if chrome_running; then
    echo "   - Chrome 正在运行：缓存照清（Chrome 会自动重建），退出后再跑一次会更干净"
  fi

  clean_dir "组件下载缓存 component_crx_cache" "$C/component_crx_cache"
  clean_dir "GPU 着色器缓存 ShaderCache"       "$C/ShaderCache"
  clean_dir "GPU 着色器缓存 GrShaderCache"     "$C/GrShaderCache"
  clean_dir "GPU 着色器缓存 GraphiteDawnCache" "$C/GraphiteDawnCache"
  clean_dir "崩溃转储 Crashpad/completed"      "$C/Crashpad/completed"

  for P in "$C"/Default "$C"/"Profile "*; do
    [ -d "$P" ] || continue
    [ "$n" -gt 1 ] && printf '   %s\n' "$(basename "$P")"

    clean_dir "Service Worker 缓存 CacheStorage" "$P/Service Worker/CacheStorage"
    clean_dir "Service Worker 脚本缓存"          "$P/Service Worker/ScriptCache"
    clean_dir "共享字典缓存"                      "$P/Shared Dictionary"
    clean_dir "GPU 缓存"                          "$P/GPUCache"
    clean_dir "Dawn / WebGPU 缓存"                "$P/DawnCache"
    clean_dir "Dawn / WebGPU 缓存（WebGPU）"      "$P/DawnWebGPUCache"
    clean_dir "Dawn Graphite 缓存"                "$P/DawnGraphiteCache"
    clean_dir "磁盘缓存 Cache"                    "$P/Cache"
    clean_dir "代码缓存 Code Cache"               "$P/Code Cache"

    kb=$(size_kb "$P/Extensions")
    ext_kb=$((ext_kb + ${kb:-0}))
  done

  echo '   （下面是 Chrome 的"用户内容"，脚本一律不动，只提示大小）'
  [ "${ext_kb:-0}" -ge 102400 ] && printf '   - 已安装扩展程序 —— %s（要精简去 chrome://extensions 卸载）\n' "$(human "$ext_kb")"
  echo '   - 书签 / 历史 / Cookie / 密码 / 网站数据（IndexedDB、Local Storage）都不动'
  echo '   - 浏览网页的 HTTP 缓存（~/Library/Caches/Google/Chrome）已由上面【应用缓存】统一清理'
  return 0
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

# ---------- WPS ----------
wps_running() { pgrep -f 'wpsoffice.app/Contents/MacOS/wpsoffice' >/dev/null 2>&1; }

do_wps() {
  local C="$HOME/Library/Containers/com.kingsoft.wpsoffice.mac/Data" kb
  if [ ! -d "$C" ]; then
    echo "   - 没找到 WPS 用户数据（未安装，或从未启动过 WPS）"
    return 0
  fi
  if wps_running; then
    echo "   - WPS 正在运行，已跳过（缓存正被它占用，退出 WPS 后再清理）"
    return 0
  fi

  clean_dir "WPS 运行日志"                 "$C/Library/Application Support/Kingsoft/office6/log"
  clean_dir "WPS 临时文件"                 "$C/tmp"
  clean_dir "WPS 崩溃/升级备份 kccsdkbak"  "$C/.kingsoft/office6/kccsdkbak"
  clean_dir "WPS 内嵌浏览器缓存 CEF"       "$C/Library/Application Support/CEF"
  clean_dir "WPS 在线字体缓存"             "$C/.kingsoft/office6/data/fonts/online_ext_font_cache"
  clean_dir "WPS 安装器缓存"               "$HOME/Library/HTTPStorages/com.kingsoft.wpsoffice.mac.installer"

  echo '   （下面是 WPS 的"用户内容"，脚本一律不动，只提示大小）'
  kb=$(size_kb "$C/.kingsoft/office6/data/backup")
  [ "${kb:-0}" -ge 1024 ] && printf '   - 文档自动备份 backup/ —— %s（误删过文档时靠它救命）\n' "$(human "$kb")"
  kb=$(size_kb "$C/.kingsoft/wps/addons")
  [ "${kb:-0}" -ge 1024 ] && printf '   - 已安装插件 addons/ —— %s（要精简请在 WPS 内卸载插件）\n' "$(human "$kb")"
  kb=$(size_kb "$C/.kingsoft/office6/data/fonts/extend_font")
  [ "${kb:-0}" -ge 1024 ] && printf '   - 已下载字体 extend_font/ —— %s（删了老文档会换字体显示，故保留）\n' "$(human "$kb")"
  kb=$(size_kb "$C/Library/Application Support/Kingsoft/WPS Cloud Files")
  [ "${kb:-0}" -ge 1024 ] && printf '   - 云文档本地缓存 WPS Cloud Files/ —— %s（离线可用的副本，别删）\n' "$(human "$kb")"
  return 0
}

do_cleanup() {
  local H="$HOME"

  echo "${BOLD}【废纸篓】${RESET}"
  clean_dir "废纸篓 ~/.Trash" "$H/.Trash"

  echo "${BOLD}【应用缓存】（应用会自动重建，首次启动可能稍慢）${RESET}"
  clean_dir "用户缓存 ~/Library/Caches"          "$H/Library/Caches"
  if running Xcode; then
    echo "   - Xcode 正在运行，已跳过 DerivedData（退出 Xcode 后再清理）"
  else
    clean_dir "Xcode 构建缓存 DerivedData"       "$H/Library/Developer/Xcode/DerivedData"
    clean_dir "Xcode 设备支持文件"               "$H/Library/Developer/Xcode/iOS DeviceSupport"
  fi
  clean_dir "模拟器缓存"                          "$H/Library/Developer/CoreSimulator/Caches"
  if running Code; then
    echo "   - VS Code 正在运行，已跳过其缓存"
  else
    clean_dir "VS Code 缓存"                      "$H/Library/Application Support/Code/Cache"
    clean_dir "VS Code CachedData"                "$H/Library/Application Support/Code/CachedData"
    clean_dir "VS Code 扩展安装包缓存"            "$H/Library/Application Support/Code/CachedExtensionVSIXs"
  fi
  if running Slack; then
    echo "   - Slack 正在运行，已跳过其缓存"
  else
    clean_dir "Slack 缓存"                        "$H/Library/Application Support/Slack/Cache"
  fi

  echo "${BOLD}【日志与诊断报告】${RESET}"
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

  if [ "$CLEAN_WECHAT" -eq 1 ]; then
    echo "${BOLD}【微信】${RESET}"
    do_wechat
  fi
  if [ "$CLEAN_CHROME" -eq 1 ]; then
    echo "${BOLD}【Chrome】${RESET}"
    do_chrome
  fi
  if [ "$CLEAN_WPS" -eq 1 ]; then
    echo "${BOLD}【WPS】${RESET}"
    do_wps
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
  echo "确认后执行:  ./mac-cleanup.sh --clean            # 微信 / Chrome / WPS / Docker 会一起清"
  echo "可选追加:  --downloads   把「下载」超过 ${DOWNLOADS_DAYS} 天的旧文件移入废纸篓"
  echo "          --docker-all  连未被使用的 Docker 镜像一起删（可多省几 GB）"
  echo "          --report      顺便列出主目录里的空间大户"
  echo "跳过某项:  --no-wechat / --no-chrome / --no-wps / --no-docker / --no-apps"
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
