FROM node:22-alpine

# Create a non-root user/group for the process
RUN addgroup -S readability && adduser -S readability -G readability

WORKDIR /app

# Install dependencies first (layer is cached unless package files change)
COPY package*.json ./
# Use npm install on first build. Once you've committed a package-lock.json,
# switch this to `npm ci --omit=dev` for reproducible, faster installs.
RUN npm install --omit=dev

# Copy application files
COPY src/ ./src/
COPY pm2.json ./

USER readability

EXPOSE 3000

# Kubernetes HEALTHCHECK — uses wget (available in alpine) to hit the /health endpoint.
# Adjust intervals to match your k8s liveness/readiness probe settings.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:3000/health || exit 1

# pm2-runtime keeps the container foreground process alive.
# PM2 will restart the Node.js process if it exceeds max_memory_restart (200M)
# before Kubernetes has to do a hard OOM kill.
CMD ["node_modules/.bin/pm2-runtime", "pm2.json"]
