FROM golang:1.21-alpine AS builder

WORKDIR /build

# 复制源代码
COPY . .

# 构建应用
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o mosdnsui web.go

# 使用Alpine作为最终镜像
FROM alpine:3.19

# 安装必要的依赖
RUN apk add --no-cache supervisor ca-certificates tzdata

# 创建必要的目录S
RUN mkdir -p /opt/mosdnsui/static /etc/mosdns/rule

# 复制构建好的二进制文件和静态资源
COPY --from=builder /build/mosdnsui /usr/local/bin/
COPY index.html /opt/mosdnsui/
COPY static/ /opt/mosdnsui/static/

# 创建默认的规则文件
RUN touch /etc/mosdns/rule/blocklist.txt \
    && touch /etc/mosdns/rule/whitelist.txt \
    && touch /etc/mosdns/rule/blockips.txt

# 设置环境变量
ENV WEB_PORT=5001
ENV MOSDNS_ADMIN_URL="http://127.0.0.1:9099"

# 暴露端口
EXPOSE 5001

# 启动命令
CMD ["mosdnsui"]