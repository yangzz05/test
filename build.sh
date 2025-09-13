#!/bin/sh

echo "开始构建 MosDNS UI Docker 镜像..."

# 构建Docker镜像
docker build -t mosdnsui:alpine .

echo "构建完成！"
echo "你可以使用以下命令运行容器："
echo "docker run -d -p 5001:5001 -e MOSDNS_ADMIN_URL=http://your-mosdns-host:9099 mosdnsui:alpine"
echo "或者使用 docker-compose up -d 命令运行"