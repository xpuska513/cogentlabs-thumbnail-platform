FROM node:20.19.0-bullseye-slim

WORKDIR /usr/src/app

COPY package.json package-lock.json tsconfig.json src .

RUN npm ci

RUN npm run build

EXPOSE 3000

CMD [ "npm", "start" ]
