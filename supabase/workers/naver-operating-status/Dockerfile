FROM mcr.microsoft.com/playwright:v1.55.1-noble

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

ENV NODE_ENV=production
CMD ["node", "src/index.js"]
