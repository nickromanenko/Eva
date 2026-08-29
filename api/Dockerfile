FROM oven/bun:1.3-slim AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1.3-slim
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
# The retention purge runs from this image as a Cloud Run job with the entrypoint
# overridden (docs/ARCHITECTURE.md §4). The server itself never runs anything in here.
COPY scripts ./scripts
USER bun
EXPOSE 8080
CMD ["bun", "run", "src/index.ts"]
