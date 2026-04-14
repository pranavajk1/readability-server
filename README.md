# readability-js-server

A lightweight HTTP server that extracts readable article content from URLs using [Mozilla Readability](https://github.com/mozilla/readability) — the same library that powers Firefox Reader View.

Built as a drop-in replacement for [phpdocker-io/readability-js-server](https://github.com/phpdocker-io/readability-js-server) with significant memory leak fixes and a smaller dependency footprint.

## API

The API is fully compatible with the original image.

**POST /**

```json
{ "url": "https://example.com/some-article" }
```

Response:

```json
{
  "url": "https://example.com/some-article",
  "title": "Article Title",
  "byline": "Author Name",
  "content": "<div>...cleaned HTML...</div>",
  "excerpt": "Short summary of the article...",
  "length": 4821,
  "dir": "ltr",
  "siteName": "Example"
}
```

**GET /health**

Returns server uptime and current memory usage. Intended for Kubernetes liveness/readiness probes.

```json
{
  "status": "ok",
  "uptime": 3600,
  "memory": {
    "rssBytes": 85983232,
    "heapUsedBytes": 42123456,
    "heapTotalBytes": 67108864
  }
}
```

## Running with Docker

```bash
docker run -p 3000:3000 ghcr.io/YOUR_USERNAME/readability-server:latest
```

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Port the server listens on |
| `FETCH_TIMEOUT_MS` | `30000` | Timeout in ms for fetching the target URL |

## Kubernetes deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: readability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: readability
  template:
    metadata:
      labels:
        app: readability
    spec:
      containers:
        - name: readability
          image: ghcr.io/pranavajk1/readability-server:latest
          ports:
            - containerPort: 3000
          env:
            - name: FETCH_TIMEOUT_MS
              value: "30000"
          resources:
            requests:
              memory: "128Mi"
            limits:
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
```

The memory limits work in two layers: PM2 triggers a graceful restart at 200 MB, and Kubernetes enforces a hard limit at 256 MB. In normal operation after the memory leaks are fixed, RSS should stay well under 100 MB.

## What was fixed vs. the original image

The original [phpdocker-io/readability-js-server](https://github.com/phpdocker-io/readability-js-server) had several issues that caused the Node.js process to accumulate memory indefinitely, eventually crashing or getting OOM-killed by Kubernetes.

### 1. JSDOM window was never closed

The single biggest source of the leak. JSDOM builds a complete in-memory DOM tree for every request. Without explicitly calling `window.close()`, every DOM tree, event listener, and associated V8 heap object from every previous request stays live forever.

**Fix:** `dom.window.close()` is called in a `finally` block, so it is guaranteed to run even if parsing throws.

```js
let dom = null;
try {
  dom = new JSDOM(html, { url, virtualConsole });
  // ...parse...
} finally {
  if (dom) {
    dom.window.close();
    dom = null;
  }
}
```

### 2. DOMPurify created a second JSDOM instance per request

The original used DOMPurify to sanitize HTML before passing it to Readability. DOMPurify itself requires a DOM environment, so it internally creates its own JSDOM instance. This meant **two** JSDOM instances were created (and leaked) per request.

**Fix:** DOMPurify was removed entirely. Mozilla Readability already strips scripts, event handlers, and dangerous markup from its output. Running a second sanitizer pass on the input was redundant.

### 3. No VirtualConsole — stdout listeners held DOM objects alive

When JSDOM is created without a `VirtualConsole`, it wires up its own console event listeners that keep references into the DOM tree. These references survive `window.close()` and prevent garbage collection.

**Fix:** A silent `VirtualConsole` is passed to every JSDOM constructor call, which disconnects the console from the DOM.

```js
const virtualConsole = new VirtualConsole(); // silent, no listeners
dom = new JSDOM(html, { url, virtualConsole });
```

### 4. No Node.js heap ceiling

Without `--max-old-space-size`, V8 will allow the heap to grow until the OS kills the process. Setting a ceiling tells V8 to run garbage collection more aggressively before reaching that limit, rather than waiting until memory pressure is extreme.

**Fix:** PM2 passes `--max-old-space-size=150` to Node.js (150 MB heap ceiling inside a container with a 256 MB limit).

### 5. No soft memory threshold before the hard OOM kill

Kubernetes kills the pod with SIGKILL when it exceeds its memory limit, dropping any in-flight requests. There was no intermediate step.

**Fix:** PM2's `max_memory_restart: 200M` triggers a graceful restart (SIGTERM → drain → exit) when the process crosses 200 MB — below the 256 MB Kubernetes hard limit. In-flight requests finish before the process exits.

### 6. axios replaced with native fetch

Node.js 22 ships a stable, built-in `fetch` with `AbortController`-based timeout support. Removing axios eliminates a dependency and its associated overhead.

### 7. Added /health endpoint

The original image had no health check endpoint. Kubernetes had no way to know if the service was actually ready to handle requests.

**Fix:** `GET /health` returns uptime and memory metrics. The Dockerfile `HEALTHCHECK` and the example Kubernetes deployment both use it.

## Building locally

```bash
npm install
node src/server.js
```

```bash
# or with PM2
npm run start:pm2
```
