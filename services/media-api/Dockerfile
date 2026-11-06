FROM node:24-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY *.mjs ./
USER node
ENV NODE_ENV=production
CMD ["node", "server.mjs"]
