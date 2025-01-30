#!/bin/bash

# 颜色输出函数
print_info() {
    echo -e "\033[32m[INFO] $1\033[0m"
}

print_error() {
    echo -e "\033[31m[ERROR] $1\033[0m"
}

print_warning() {
    echo -e "\033[33m[WARNING] $1\033[0m"
}

# 检查操作系统类型
check_os() {
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
        # 检查是否是 CentOS Stream
        if grep -q "CentOS Stream" /etc/redhat-release; then
            OS_VERSION="stream"
        else
            OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
        fi
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version | cut -d. -f1)
    else
        print_error "不支持的操作系统"
        exit 1
    fi
}

# 获取可用的 Java 版本
get_available_versions() {
    # 获取 Amazon Corretto 版本列表
    local versions=$(curl -s https://corretto.aws/downloads/latest_checksum | \
                    grep -oE "amazon-corretto-[0-9]+" | \
                    cut -d'-' -f3 | \
                    sort -V | \
                    uniq)
    
    if [ -z "$versions" ]; then
        # 如果无法获取在线版本，则提供固定版本列表
        echo "8"
        echo "11"
        echo "17"
        echo "21"
    else
        echo "$versions"
    fi
}

# 选择 Java 版本
select_java_version() {
    print_info "获取 Amazon Corretto 可用版本列表..."
    
    # 使用临时文件存储版本列表
    local temp_file="/tmp/java_versions.tmp"
    get_available_versions > "$temp_file"
    
    # 读取版本到数组
    local versions=()
    while IFS= read -r version; do
        versions+=("$version")
    done < "$temp_file"
    rm -f "$temp_file"
    
    if [ ${#versions[@]} -eq 0 ]; then
        print_error "无法获取 Java 版本列表"
        exit 1
    fi
    
    local latest_version=${versions[-1]}
    
    echo -e "\n可用的 Java 版本:"
    local i=1
    for version in "${versions[@]}"; do
        echo "$i) Java $version"
        ((i++))
    done
    
    echo
    read -p "请选择版本号（1-${#versions[@]}），直接回车将安装最新版 Java $latest_version: " choice
    
    if [ -z "$choice" ]; then
        JAVA_VERSION=$latest_version
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#versions[@]}" ]; then
        JAVA_VERSION=${versions[$((choice-1))]}
    else
        print_error "无效的选择，将使用最新版 Java $latest_version"
        JAVA_VERSION=$latest_version
    fi
    
    print_info "选择的 Java 版本: $JAVA_VERSION"
}

# 安装 Java
install_java() {
    print_info "开始安装 Amazon Corretto $JAVA_VERSION..."
    
    # 创建临时目录
    local temp_dir="/tmp/corretto"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # 根据系统架构选择下载链接
    local arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        arch="x64"
    elif [ "$arch" = "aarch64" ]; then
        arch="aarch64"
    else
        print_error "不支持的系统架构: $arch"
        exit 1
    fi
    
    # 下载并安装 Corretto
    local download_url="https://corretto.aws/downloads/latest/amazon-corretto-${JAVA_VERSION}-${arch}-linux-jdk.tar.gz"
    print_info "下载 Amazon Corretto: $download_url"
    
    if ! wget -q "$download_url"; then
        print_error "下载失败"
        exit 1
    fi
    
    # 创建安装目录
    local install_dir="/usr/lib/jvm"
    mkdir -p "$install_dir"
    
    # 解压安装
    print_info "解压并安装..."
    tar xf "amazon-corretto-${JAVA_VERSION}-${arch}-linux-jdk.tar.gz" -C "$install_dir"
    
    # 获取解压后的目录名
    local corretto_dir=$(ls "$install_dir" | grep "amazon-corretto-${JAVA_VERSION}")
    if [ -z "$corretto_dir" ]; then
        print_error "无法找到安装目录"
        exit 1
    fi
    
    # 设置 JAVA_HOME
    JAVA_HOME="${install_dir}/${corretto_dir}"
    
    # 创建符号链接
    ln -sf "${JAVA_HOME}/bin/java" /usr/bin/java
    ln -sf "${JAVA_HOME}/bin/javac" /usr/bin/javac
    
    # 清理临时文件
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    if [ $? -ne 0 ]; then
        print_error "Java 安装失败"
        exit 1
    fi
}

# 配置 Java 环境变量
configure_java() {
    print_info "配置 Java 环境变量..."
    
    # 配置环境变量
    cat > /etc/profile.d/java.sh << EOF
export JAVA_HOME=$JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    
    chmod +x /etc/profile.d/java.sh
    source /etc/profile.d/java.sh
}

# 验证安装
verify_installation() {
    print_info "验证 Java 安装..."
    
    if ! command -v java &>/dev/null; then
        print_error "Java 安装验证失败"
        exit 1
    fi
    
    java -version
    print_info "Java 安装验证成功"
}

# 检查基础工具
check_base_tools() {
    print_info "检查基础工具..."
    
    # 检查必需的命令
    local required_tools="wget curl tar"
    local missing_tools=""
    
    for tool in $required_tools; do
        if ! command -v $tool &>/dev/null; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    if [ -n "$missing_tools" ]; then
        print_warning "缺少必要的工具:$missing_tools"
        print_info "开始安装基础工具..."
        
        # 检查基础工具安装脚本是否存在
        local base_tools_script="$(dirname $0)/install_base_tools.sh"
        if [ ! -f "$base_tools_script" ]; then
            print_error "找不到基础工具安装脚本: $base_tools_script"
            exit 1
        fi
        
        # 执行基础工具安装脚本
        bash "$base_tools_script"
        if [ $? -ne 0 ]; then
            print_error "基础工具安装失败"
            exit 1
        fi
        
        print_info "基础工具安装完成"
    else
        print_info "基础工具检查通过"
    fi
}

# 检查现有 Java 环境
check_existing_java() {
    print_info "检查现有 Java 环境..."
    
    if command -v java &>/dev/null; then
        local current_version=$(java -version 2>&1 | grep -i version | cut -d'"' -f2)
        local current_home=""
        
        # 获取当前 JAVA_HOME
        if [ -n "$JAVA_HOME" ]; then
            current_home="$JAVA_HOME"
        elif [ -f "/etc/profile.d/java.sh" ]; then
            current_home=$(source "/etc/profile.d/java.sh" && echo "$JAVA_HOME")
        fi
        
        print_warning "检测到已安装的 Java 环境:"
        echo "Java 版本: $current_version"
        if [ -n "$current_home" ]; then
            echo "JAVA_HOME: $current_home"
        fi
        
        # 询问用户是否继续安装
        read -p "是否继续安装新的 Java 版本？(y/N) " choice
        case "$choice" in
            [yY]|[yY][eE][sS])
                print_info "继续安装新的 Java 版本..."
                ;;
            *)
                print_info "取消安装"
                exit 0
                ;;
        esac
    else
        print_info "未检测到已安装的 Java 环境，继续安装..."
    fi
}

# 主函数
main() {
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    check_os
    check_base_tools
    check_existing_java
    select_java_version
    install_java
    configure_java
    verify_installation
    
    print_info "Java 安装完成！"
    print_info "请运行 'source /etc/profile' 或重新登录以使环境变量生效"
}

# 执行主函数
main 