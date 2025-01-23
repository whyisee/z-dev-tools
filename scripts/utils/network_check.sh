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

# 检查网络连接
check_network() {
    local target=$1
    local timeout=5

    print_info "检查网络连接: $target"
    
    # 尝试 ping
    if ping -c 1 -W $timeout $target >/dev/null 2>&1; then
        print_info "网络连接正常"
        return 0
    fi

    print_error "无法连接到 $target"
    print_warning "请检查以下内容："
    echo "1. 检查网络连接是否正常"
    echo "2. 检查 DNS 设置"
    echo "3. 如果使用代理，请确认代理设置是否正确"
    
    # 提供解决方案
    echo -e "\n可能的解决方案："
    echo "1. 设置 Git 使用 HTTPS 代理:"
    echo "   git config --global http.proxy http://your-proxy:port"
    echo "   git config --global https.proxy https://your-proxy:port"
    echo
    echo "2. 或者使用 SSH 方式连接 GitHub:"
    echo "   git remote set-url origin git@github.com:username/repository.git"
    echo
    echo "3. 添加 GitHub 到 hosts 文件:"
    echo "   echo '140.82.114.4 github.com' >> /etc/hosts"
    echo
    echo "4. 临时使用国内镜像:"
    echo "   git remote set-url origin https://gitee.com/username/repository.git"
    
    return 1
}

# 配置 Git 代理
configure_git_proxy() {
    local proxy_host=$1
    local proxy_port=$2
    
    if [ -z "$proxy_host" ] || [ -z "$proxy_port" ]; then
        print_error "请提供代理服务器地址和端口"
        echo "使用方法: configure_git_proxy proxy_host proxy_port"
        echo "示例: configure_git_proxy 127.0.0.1 7890"
        return 1
    }
    
    print_info "配置 Git 代理..."
    git config --global http.proxy "http://$proxy_host:$proxy_port"
    git config --global https.proxy "http://$proxy_host:$proxy_port"
    
    print_info "Git 代理配置完成"
    git config --global --get http.proxy
    git config --global --get https.proxy
}

# 移除 Git 代理配置
remove_git_proxy() {
    print_info "移除 Git 代理配置..."
    git config --global --unset http.proxy
    git config --global --unset https.proxy
    print_info "Git 代理配置已移除"
}

# 主函数
main() {
    local command=$1
    case $command in
        "check")
            check_network "github.com"
            ;;
        "set-proxy")
            configure_git_proxy $2 $3
            ;;
        "remove-proxy")
            remove_git_proxy
            ;;
        *)
            echo "使用方法:"
            echo "  $0 check              - 检查网络连接"
            echo "  $0 set-proxy host port - 设置 Git 代理"
            echo "  $0 remove-proxy        - 移除 Git 代理"
            ;;
    esac
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 