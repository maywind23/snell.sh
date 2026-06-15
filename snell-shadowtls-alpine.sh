#!/bin/sh
# =========================================
# 作者: jinqians
# 日期: 2026年6月13日
# 描述: Alpine Linux 一键安装 Snell + ShadowTLS V3 节点
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

INSTALL_DIR="/usr/local/bin"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SNELL_SERVICE_FILE="/etc/init.d/snell"
SHADOWTLS_CONF_DIR="/etc/shadowtls"
SHADOWTLS_CONF_FILE="${SHADOWTLS_CONF_DIR}/snell.env"
SHADOWTLS_SERVICE_FILE="/etc/init.d/shadowtls-snell"
SNELL_COMMAND="${INSTALL_DIR}/snell-server"
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本。${RESET}"
        exit 1
    fi
}

check_system() {
    if [ ! -f /etc/alpine-release ]; then
        echo -e "${RED}错误: 此脚本仅适用于 Alpine Linux 系统。${RESET}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${CYAN}正在安装依赖...${RESET}"
    apk update
    apk add --no-cache curl wget unzip openssl iptables ip6tables openrc net-tools file coreutils binutils tar gzip xz libc6-compat libstdc++ libgcc gcompat

    # Snell 官方 Linux 二进制依赖 glibc。Alpine 下优先安装 sgerrand glibc，失败时仍保留 gcompat 作为兜底。
    if [ ! -f /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ] && [ "$(uname -m)" = "x86_64" ]; then
        GLIBC_VERSION="2.35-r0"
        echo -e "${CYAN}正在安装 glibc 兼容包...${RESET}"
        curl -fsSL -o /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub || true
        curl -fsSL -o /tmp/glibc.apk "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk" || true
        curl -fsSL -o /tmp/glibc-bin.apk "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-bin-${GLIBC_VERSION}.apk" || true
        if [ -f /tmp/glibc.apk ] && [ -f /tmp/glibc-bin.apk ]; then
            apk add --allow-untrusted --force-overwrite /tmp/glibc.apk /tmp/glibc-bin.apk || true
        fi
        rm -f /tmp/glibc.apk /tmp/glibc-bin.apk
    fi

    fix_glibc_loader_links
}

fix_glibc_loader_links() {
    # Alpine 的 gcompat/sgerrand glibc 常提供 /lib/ld-linux-x86-64.so.2，
    # 但 Snell amd64 二进制的 ELF interpreter 可能寻找 /lib64/ld-linux-x86-64.so.2。
    # 缺少该路径时，直接执行会报 not found，之前会被误判为“兼容性测试失败”。
    if [ "$(uname -m)" = "x86_64" ]; then
        mkdir -p /lib64
        if [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
            if [ -e /lib/ld-linux-x86-64.so.2 ]; then
                ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
            elif [ -e /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ]; then
                ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
            fi
        fi
    fi
}

get_debian_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armhf" ;;
        *) return 1 ;;
    esac
}

get_debian_package_filename() {
    deb_arch=$1
    package_name=$2
    index_file=$(mktemp)
    curl -fsSL -o "$index_file" "https://deb.debian.org/debian/dists/bookworm/main/binary-${deb_arch}/Packages.gz" || {
        rm -f "$index_file"
        return 1
    }
    gzip -dc "$index_file" | awk -v pkg="$package_name" '
        $1 == "Package:" { in_pkg = ($2 == pkg) }
        in_pkg && $1 == "Filename:" { print $2; exit }
    '
    status=$?
    rm -f "$index_file"
    return "$status"
}

extract_debian_package_libs() {
    deb_file=$1
    extract_dir=$2
    work_dir=$(mktemp -d)
    (
        cd "$work_dir" || exit 1
        ar x "$deb_file"
        data_archive=$(printf '%s\n' data.tar.* | head -n 1)
        tar -xf "$data_archive" -C "$extract_dir"
    )
    status=$?
    rm -rf "$work_dir"
    return "$status"
}

install_debian_glibc_runtime() {
    # 参考原作者 Dockerfile 的处理方式：不用 Alpine 自带 gcompat 跑 Snell v5，
    # 而是从 Debian bookworm 提取 glibc/libstdc++/libgcc 运行库到 /usr/glibc-compat/lib。
    deb_arch=$(get_debian_arch) || { echo -e "${RED}不支持注入 Debian glibc 的架构: $(uname -m)${RESET}"; exit 1; }
    runtime_dir="/usr/glibc-compat/lib"
    tmp_dir=$(mktemp -d)
    mkdir -p "$runtime_dir"

    echo -e "${CYAN}正在注入 Debian bookworm glibc 运行库（用于 Snell v5）...${RESET}"
    for pkg in libc6 libstdc++6 libgcc-s1; do
        filename=$(get_debian_package_filename "$deb_arch" "$pkg")
        if [ -z "$filename" ]; then
            echo -e "${RED}无法解析 Debian 包: ${pkg}${RESET}"
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! curl -fsSL -o "${tmp_dir}/${pkg}.deb" "https://deb.debian.org/debian/${filename}"; then
            echo -e "${RED}下载 Debian 包失败: ${pkg}${RESET}"
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! extract_debian_package_libs "${tmp_dir}/${pkg}.deb" "$tmp_dir"; then
            echo -e "${RED}解压 Debian 包失败: ${pkg}${RESET}"
            rm -rf "$tmp_dir"
            exit 1
        fi
    done

    case "$deb_arch" in
        amd64) gnu_lib_dir="x86_64-linux-gnu"; loader="ld-linux-x86-64.so.2"; loader_link="/lib64/ld-linux-x86-64.so.2" ;;
        arm64) gnu_lib_dir="aarch64-linux-gnu"; loader="ld-linux-aarch64.so.1"; loader_link="/lib/ld-linux-aarch64.so.1" ;;
        armhf) gnu_lib_dir="arm-linux-gnueabihf"; loader="ld-linux-armhf.so.3"; loader_link="/lib/ld-linux-armhf.so.3" ;;
    esac

    cp -a "${tmp_dir}/lib/${gnu_lib_dir}/"*.so* "$runtime_dir"/ 2>/dev/null || true
    cp -a "${tmp_dir}/usr/lib/${gnu_lib_dir}/"*.so* "$runtime_dir"/ 2>/dev/null || true
    loader_path=$(find "$tmp_dir" -name "$loader" | head -n 1)
    rm -f "${runtime_dir}/${loader}"
    if [ -n "$loader_path" ]; then
        if [ -L "$loader_path" ]; then
            loader_target=$(readlink "$loader_path")
            case "$loader_target" in
                /*) resolved_loader="${tmp_dir}${loader_target}" ;;
                *) resolved_loader="$(dirname "$loader_path")/${loader_target}" ;;
            esac
            if [ -e "$resolved_loader" ]; then
                cp -a "$resolved_loader" "${runtime_dir}/${loader}"
            else
                cp -L "$loader_path" "${runtime_dir}/${loader}"
            fi
        else
            cp -a "$loader_path" "${runtime_dir}/${loader}"
        fi
    fi
    mkdir -p "$(dirname "$loader_link")"
    if [ -f "${runtime_dir}/${loader}" ]; then
        ln -sf "${runtime_dir}/${loader}" "$loader_link"
    else
        echo -e "${RED}未找到 Debian glibc loader: ${loader}${RESET}"
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
    echo -e "${GREEN}✓ Debian glibc 运行库注入完成。${RESET}"
}

select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5（Alpine 将注入 Debian glibc 运行库）"
    while true; do
        printf "请输入选项 [1-2]，回车默认 [2]: "
        read -r choice
        [ -z "$choice" ] && choice="2"
        case "$choice" in
            1) SNELL_VERSION_CHOICE="v4"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; break ;;
            *) echo -e "${RED}请输入正确的选项 [1-2]${RESET}" ;;
        esac
    done
}

get_latest_snell_v4_version() {
    latest_version=$(curl -fsSL https://manual.nssurge.com/others/snell.html 2>/dev/null | grep -o 'snell-server-v4\.[0-9]\+\.[0-9]\+' | head -n 1 | sed 's/snell-server-v//')
    if [ -n "$latest_version" ]; then echo "v${latest_version}"; else echo "v4.1.1"; fi
}

get_latest_snell_v5_version() {
    latest_version=$(curl -fsSL https://manual.nssurge.com/others/snell.html 2>/dev/null | grep -o 'snell-server-v5\.[0-9][0-9A-Za-z.]*' | head -n 1 | sed 's/snell-server-v//')
    if [ -n "$latest_version" ]; then echo "v${latest_version}"; else echo "v5.0.1"; fi
}

get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else
        SNELL_VERSION=$(get_latest_snell_v4_version)
    fi
    echo -e "${GREEN}Snell 版本: ${SNELL_VERSION}${RESET}"
}

get_snell_download_url() {
    case "$(uname -m)" in
        x86_64|amd64) arch_suffix="amd64" ;;
        aarch64|arm64) arch_suffix="aarch64" ;;
        armv7l|armv7) arch_suffix="armv7l" ;;
        i386|i686) arch_suffix="i386" ;;
        *) echo -e "${RED}不支持的 Snell 架构: $(uname -m)${RESET}" >&2; exit 1 ;;
    esac
    echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${arch_suffix}.zip"
}

get_latest_shadowtls_version() {
    latest_version=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/ihciah/shadow-tls/releases/latest 2>/dev/null | sed -E 's#.*/tag/##')
    if [ -z "$latest_version" ] || [ "$latest_version" = "https://github.com/ihciah/shadow-tls/releases/latest" ]; then
        echo -e "${RED}获取 ShadowTLS 最新版本失败。${RESET}" >&2
        exit 1
    fi
    echo "$latest_version"
}

get_shadowtls_download_url() {
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) arch="aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持的 ShadowTLS 架构: $(uname -m)${RESET}" >&2; exit 1 ;;
    esac
    version=$(get_latest_shadowtls_version)
    echo "https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${arch}"
}

random_port() {
    shuf -i 20000-65000 -n 1
}

is_port_used() {
    netstat -tuln 2>/dev/null | grep -q "[:.]$1 "
}

ask_port() {
    prompt=$1
    while true; do
        printf "%s (1-65535)，回车随机: " "$prompt" >&2
        read -r port
        if [ -z "$port" ]; then
            port=$(random_port)
            while is_port_used "$port"; do port=$(random_port); done
            echo -e "${YELLOW}使用随机端口: ${port}${RESET}" >&2
            echo "$port"
            return 0
        fi
        case "$port" in *[!0-9]*|'') echo -e "${RED}请输入纯数字端口。${RESET}" >&2; continue ;; esac
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && ! is_port_used "$port"; then
            echo "$port"
            return 0
        fi
        echo -e "${RED}端口无效或已被占用，请重新输入。${RESET}" >&2
    done
}

open_port() {
    port=$1
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
    fi
    rc-update add iptables boot >/dev/null 2>&1 || true
    [ -x /etc/init.d/iptables ] && /etc/init.d/iptables save >/dev/null 2>&1 || true
    if [ -x /etc/init.d/ip6tables ]; then
        rc-update add ip6tables boot >/dev/null 2>&1 || true
        /etc/init.d/ip6tables save >/dev/null 2>&1 || true
    fi
}

download_snell_binary() {
    snell_url=$(get_snell_download_url)
    echo -e "${CYAN}正在下载 Snell: ${snell_url}${RESET}"
    tmp_dir=$(mktemp -d)
    curl -fL -o "${tmp_dir}/snell-server.zip" "$snell_url"
    unzip -o "${tmp_dir}/snell-server.zip" -d "$tmp_dir"
    install -m 755 "${tmp_dir}/snell-server" "${INSTALL_DIR}/snell-server"
    rm -rf "$tmp_dir"
}

install_snell_binary() {
    select_snell_version
    get_latest_snell_version

    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        install_debian_glibc_runtime
    fi

    download_snell_binary

    if verify_snell_binary; then
        return 0
    fi

    echo -e "${RED}Snell ${SNELL_VERSION} 兼容性测试失败。${RESET}"
    echo -e "${YELLOW}最近一次检测输出:${RESET}"
    cat /tmp/snell-probe.log 2>/dev/null || true
    echo -e "${YELLOW}可尝试手动执行: ${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}${RESET}"
    exit 1
}

run_snell_probe() {
    probe_cmd=$1
    shift

    : > /tmp/snell-probe.log

    # v4 支持 -v/--version/--help；v5 可能不接受这些探测参数，所以不能只靠版本参数判断。
    if timeout 5s "$probe_cmd" "$@" -v >>/tmp/snell-probe.log 2>&1 || \
        timeout 5s "$probe_cmd" "$@" --version >>/tmp/snell-probe.log 2>&1 || \
        timeout 5s "$probe_cmd" "$@" --help >>/tmp/snell-probe.log 2>&1; then
        return 0
    fi

    # 对不支持版本/帮助参数的 Snell，使用临时配置实际拉起服务。
    # timeout 返回 124 代表服务持续运行到超时，说明二进制可正常执行。
    probe_port=$(random_port)
    probe_conf=$(mktemp /tmp/snell-probe.XXXXXX.conf)
    cat > "$probe_conf" <<EOF_PROBE_CONF
[snell-server]
listen = 127.0.0.1:${probe_port}
psk = snell-probe
ipv6 = false
tfo = false
EOF_PROBE_CONF

    timeout 3s "$probe_cmd" "$@" -c "$probe_conf" >>/tmp/snell-probe.log 2>&1
    probe_status=$?
    rm -f "$probe_conf"
    [ "$probe_status" -eq 0 ] || [ "$probe_status" -eq 124 ]
}

is_dynamic_elf() {
    if command -v file >/dev/null 2>&1; then
        file "$1" 2>/dev/null | grep -qi 'dynamically linked'
        return $?
    fi
    # 没有 file 时保守尝试 loader 路径。
    return 0
}

verify_snell_binary() {
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib:/usr/local/lib:/usr/lib:/lib:${LD_LIBRARY_PATH}"
    export GLIBC_TUNABLES="glibc.pthread.rseq=0"
    fix_glibc_loader_links

    if run_snell_probe "${INSTALL_DIR}/snell-server"; then
        SNELL_COMMAND="${INSTALL_DIR}/snell-server"
        return 0
    fi

    if is_dynamic_elf "${INSTALL_DIR}/snell-server"; then
        for loader in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 /usr/glibc-compat/lib/ld-linux-x86-64.so.2; do
            if [ -x "$loader" ] && run_snell_probe "$loader" "${INSTALL_DIR}/snell-server"; then
                cat > "${INSTALL_DIR}/snell-server-wrapper" <<EOF_WRAPPER
#!/bin/sh
export LD_LIBRARY_PATH="/usr/glibc-compat/lib:/usr/local/lib:/usr/lib:/lib:\${LD_LIBRARY_PATH}"
export GLIBC_TUNABLES="glibc.pthread.rseq=0"
exec ${loader} ${INSTALL_DIR}/snell-server "\$@"
EOF_WRAPPER
                chmod +x "${INSTALL_DIR}/snell-server-wrapper"
                SNELL_COMMAND="${INSTALL_DIR}/snell-server-wrapper"
                return 0
            fi
        done
    fi

    return 1
}

install_shadowtls_binary() {
    shadowtls_url=$(get_shadowtls_download_url)
    echo -e "${CYAN}正在下载 ShadowTLS: ${shadowtls_url}${RESET}"
    curl -fL -o /tmp/shadow-tls.tmp "$shadowtls_url"
    install -m 755 /tmp/shadow-tls.tmp "${INSTALL_DIR}/shadow-tls"
    rm -f /tmp/shadow-tls.tmp
}

create_snell_config_and_service() {
    mkdir -p "${SNELL_CONF_DIR}/users" /var/log/snell
    snell_port=$(ask_port "请输入 Snell 后端端口")
    snell_psk=$(openssl rand -base64 16)
    cat > "${SNELL_CONF_FILE}" <<EOF_SNELL_CONF
[snell-server]
listen = 127.0.0.1:${snell_port}
psk = ${snell_psk}
ipv6 = true
tfo = true
version-choice = ${SNELL_VERSION_CHOICE}
EOF_SNELL_CONF

    cat > "${SNELL_SERVICE_FILE}" <<EOF_SNELL_SERVICE
#!/sbin/openrc-run
name="Snell Server"
description="Snell proxy server backend for ShadowTLS"
command="${SNELL_COMMAND}"
command_args="-c ${SNELL_CONF_FILE}"
command_user="nobody"
command_background="yes"
pidfile="/run/snell.pid"
start_stop_daemon_args="--make-pidfile --stdout /var/log/snell/snell.log --stderr /var/log/snell/snell.log"

depend() {
    need net
}

start_pre() {
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib:\${LD_LIBRARY_PATH}"
    export GLIBC_TUNABLES="glibc.pthread.rseq=0"
    checkpath --directory --owner nobody:nobody --mode 0755 /var/log/snell
}
EOF_SNELL_SERVICE
    chmod +x "${SNELL_SERVICE_FILE}"
    rc-update add snell default
    rc-service snell restart
}

create_shadowtls_config_and_service() {
    mkdir -p "${SHADOWTLS_CONF_DIR}" /var/log/shadowtls
    stls_port=$(ask_port "请输入 ShadowTLS 对外监听端口")
    printf "请输入 TLS 伪装域名，回车默认 [www.microsoft.com]: "
    read -r tls_domain
    [ -z "$tls_domain" ] && tls_domain="www.microsoft.com"
    stls_password=$(openssl rand -base64 16 | tr '+/' '-_' | tr -d '=')

    cat > "${SHADOWTLS_CONF_FILE}" <<EOF_STLS_CONF
SNELL_PORT="${snell_port}"
SHADOWTLS_PORT="${stls_port}"
SHADOWTLS_PASSWORD="${stls_password}"
SHADOWTLS_SNI="${tls_domain}"
EOF_STLS_CONF
    chmod 600 "${SHADOWTLS_CONF_FILE}"

    cat > "${SHADOWTLS_SERVICE_FILE}" <<'EOF_STLS_SERVICE'
#!/sbin/openrc-run
name="ShadowTLS for Snell"
description="ShadowTLS v3 frontend for Snell on Alpine"
command="/usr/local/bin/shadow-tls"
command_background="yes"
pidfile="/run/shadowtls-snell.pid"
output_log="/var/log/shadowtls/snell.log"
error_log="/var/log/shadowtls/snell.log"
start_stop_daemon_args="--make-pidfile --stdout ${output_log} --stderr ${error_log}"

 depend() {
    need net snell
    after snell
}

start_pre() {
    if [ ! -f /etc/shadowtls/snell.env ]; then
        eerror "缺少配置文件: /etc/shadowtls/snell.env"
        return 1
    fi
    . /etc/shadowtls/snell.env
    checkpath --directory --owner root:root --mode 0755 /var/log/shadowtls
    command_args="--v3 server --listen ::0:${SHADOWTLS_PORT} --server 127.0.0.1:${SNELL_PORT} --tls ${SHADOWTLS_SNI} --password ${SHADOWTLS_PASSWORD}"
}
EOF_STLS_SERVICE
    # 修复 heredoc 中 OpenRC 函数前的缩进，避免老版本 shellcheck/OpenRC 误判。
    sed -i 's/^ depend()/depend()/' "${SHADOWTLS_SERVICE_FILE}"
    chmod +x "${SHADOWTLS_SERVICE_FILE}"
    rc-update add shadowtls-snell default
    rc-service shadowtls-snell restart
    open_port "$stls_port"
}

get_server_ip() {
    ipv4=$(curl -fsS4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if [ -n "$ipv4" ]; then echo "$ipv4"; return; fi
    curl -fsS6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null || true
}

show_information() {
    server_ip=$(get_server_ip)
    [ -z "$server_ip" ] && server_ip="<服务器IP>"
    snell_version="4"
    [ "$SNELL_VERSION_CHOICE" = "v5" ] && snell_version="5"

    echo -e "${BLUE}============================================${RESET}"
    echo -e "${GREEN}Snell + ShadowTLS 安装完成${RESET}"
    echo -e "${BLUE}============================================${RESET}"
    echo -e "Snell 后端: 127.0.0.1:${snell_port}"
    echo -e "Snell PSK: ${snell_psk}"
    echo -e "ShadowTLS 端口: ${stls_port}"
    echo -e "ShadowTLS 密码: ${stls_password}"
    echo -e "ShadowTLS SNI: ${tls_domain}"
    echo -e "${YELLOW}Surge 配置:${RESET}"
    if [ "$snell_version" = "5" ]; then
        echo -e "${GREEN}Snell-v4-STLS = snell, ${server_ip}, ${stls_port}, psk=${snell_psk}, version=4, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3${RESET}"
        echo -e "${GREEN}Snell-v5-STLS = snell, ${server_ip}, ${stls_port}, psk=${snell_psk}, version=5, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3${RESET}"
    else
        echo -e "${GREEN}Snell-STLS = snell, ${server_ip}, ${stls_port}, psk=${snell_psk}, version=4, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3${RESET}"
    fi
    echo -e "${YELLOW}配置文件:${RESET} ${SNELL_CONF_FILE} / ${SHADOWTLS_CONF_FILE}"
    echo -e "${YELLOW}日志文件:${RESET} /var/log/snell/snell.log /var/log/shadowtls/snell.log"
}

uninstall_all() {
    rc-service shadowtls-snell stop 2>/dev/null || true
    rc-update del shadowtls-snell default 2>/dev/null || true
    rc-service snell stop 2>/dev/null || true
    rc-update del snell default 2>/dev/null || true
    if [ -f "${SHADOWTLS_CONF_FILE}" ]; then
        . "${SHADOWTLS_CONF_FILE}"
        [ -n "$SHADOWTLS_PORT" ] && iptables -D INPUT -p tcp --dport "$SHADOWTLS_PORT" -j ACCEPT 2>/dev/null || true
        [ -n "$SHADOWTLS_PORT" ] && ip6tables -D INPUT -p tcp --dport "$SHADOWTLS_PORT" -j ACCEPT 2>/dev/null || true
    fi
    rm -f "${SNELL_SERVICE_FILE}" "${SHADOWTLS_SERVICE_FILE}" "${INSTALL_DIR}/snell-server" "${INSTALL_DIR}/snell-server-wrapper" "${INSTALL_DIR}/shadow-tls"
    rm -rf "${SNELL_CONF_DIR}" "${SHADOWTLS_CONF_DIR}" /var/log/snell /var/log/shadowtls
    echo -e "${GREEN}Snell + ShadowTLS 已卸载。${RESET}"
}

install_all() {
    install_dependencies
    install_snell_binary
    install_shadowtls_binary
    create_snell_config_and_service
    create_shadowtls_config_and_service
    show_information
}

main_menu() {
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN} Alpine Snell + ShadowTLS 一键脚本${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 / 重装 Snell + ShadowTLS"
    echo -e "${GREEN}2.${RESET} 查看当前配置"
    echo -e "${GREEN}3.${RESET} 卸载 Snell + ShadowTLS"
    echo -e "${GREEN}0.${RESET} 退出"
    printf "请输入选项 [0-3]: "
    read -r menu_choice
    case "$menu_choice" in
        1) install_all ;;
        2)
            if [ -f "$SNELL_CONF_FILE" ] && [ -f "$SHADOWTLS_CONF_FILE" ]; then
                snell_port=$(sed -n 's/^listen = 127\.0\.0\.1://p' "$SNELL_CONF_FILE")
                snell_psk=$(sed -n 's/^psk = //p' "$SNELL_CONF_FILE")
                SNELL_VERSION_CHOICE=$(sed -n 's/^version-choice = //p' "$SNELL_CONF_FILE")
                . "$SHADOWTLS_CONF_FILE"
                stls_port="$SHADOWTLS_PORT" stls_password="$SHADOWTLS_PASSWORD" tls_domain="$SHADOWTLS_SNI"
                show_information
            else
                echo -e "${RED}未找到完整配置，请先安装。${RESET}"
            fi
            ;;
        3) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项。${RESET}"; exit 1 ;;
    esac
}

check_root
check_system
main_menu
