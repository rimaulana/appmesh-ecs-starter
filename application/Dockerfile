FROM node:alpine
WORKDIR /usr/local/data
COPY app.js package.json package-lock.json ./
RUN npm install --only=prod
CMD ["node","app.js"]