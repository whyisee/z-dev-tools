#!/bin/bash

# 创建主目录结构
mkdir -p devops-tools/{scripts,docs,config}
mkdir -p devops-tools/scripts/{installation,monitoring,maintenance}
mkdir -p devops-tools/config/{env,templates}

# 创建 README 文件
touch devops-tools/README.md
touch devops-tools/requirements.txt 