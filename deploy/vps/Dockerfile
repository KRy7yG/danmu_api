# danmu_api 本体镜像（VPS 用，比上游 Dockerfile 精简）
# 与上游的区别：装依赖后清掉 npm 缓存、跳过可选依赖，镜像小几百 MB，
# 在 10–20 GB 的小盘 VPS 上更不容易把磁盘写满。
FROM node:22-alpine

WORKDIR /app

# 先只拷贝清单，利用层缓存
COPY package*.json ./

# --omit=dev: 本项目无 devDependencies，显式声明避免意外安装
# npm cache clean: npm 缓存默认留在 /root/.npm，白占几十 MB
RUN npm install --omit=dev --no-audit --no-fund \
    && npm cache clean --force \
    && rm -rf /root/.npm /tmp/*

COPY danmu_api/ ./danmu_api/
COPY config/ ./config_example/

ENV NODE_ENV=production
EXPOSE 9321

CMD ["node", "danmu_api/server.js"]
