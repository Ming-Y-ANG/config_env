FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY server.js ./
COPY index.html ./public/
EXPOSE 65000
CMD ["node", "server.js"]
