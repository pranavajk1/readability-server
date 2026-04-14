'use strict';

const express = require('express');
const { Readability } = require('@mozilla/readability');
const { JSDOM, VirtualConsole } = require('jsdom');

const app = express();
const PORT = parseInt(process.env.PORT || '3000', 10);
const FETCH_TIMEOUT_MS = parseInt(process.env.FETCH_TIMEOUT_MS || '30000', 10);

app.use(express.json({ limit: '10mb' }));

// Health check for kubernetes liveness/readiness probes
app.get('/health', (_req, res) => {
  const mem = process.memoryUsage();
  res.json({
    status: 'ok',
    uptime: Math.floor(process.uptime()),
    memory: {
      rssBytes: mem.rss,
      heapUsedBytes: mem.heapUsed,
      heapTotalBytes: mem.heapTotal,
    },
  });
});

app.get('/', (_req, res) => {
  res.status(400).json({
    error: 'This endpoint only accepts POST requests',
    usage: 'POST / with JSON body: { "url": "https://example.com/article" }',
  });
});

app.post('/', async (req, res) => {
  const { url } = req.body ?? {};

  if (!url || typeof url !== 'string') {
    return res.status(400).json({ error: '"url" field is required' });
  }

  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    return res.status(400).json({ error: 'Invalid URL' });
  }

  if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
    return res.status(400).json({ error: 'Only http and https URLs are supported' });
  }

  // dom is declared outside try so the finally block can always clean it up
  let dom = null;

  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    let response;
    try {
      response = await fetch(url, {
        signal: controller.signal,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
          Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.5',
        },
      });
    } finally {
      clearTimeout(timeoutId);
    }

    if (!response.ok) {
      return res.status(502).json({ error: `Failed to fetch URL: HTTP ${response.status}` });
    }

    const contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('text/html') && !contentType.includes('application/xhtml')) {
      return res.status(422).json({ error: 'URL does not point to an HTML document' });
    }

    const html = await response.text();

    // A silent VirtualConsole prevents JSDOM from printing to stdout and,
    // more importantly, prevents console event listeners from holding DOM
    // objects alive after window.close().
    const virtualConsole = new VirtualConsole();
    // Without a 'jsdomError' listener, JSDOM throws CSS parse errors as real
    // exceptions. Modern sites use CSS custom properties (e.g. var(--x, 1px))
    // that JSDOM's parser can't handle — these are non-fatal and don't affect
    // Readability's ability to extract article content, so we suppress them.
    virtualConsole.on('jsdomError', () => {});

    // Key memory leak fix: do NOT pass `resources: 'usable'`.
    // The default (no external resources) means JSDOM will not fetch
    // any external CSS, images, or scripts referenced in the HTML.
    // The original image's use of DOMPurify also created a *second*
    // JSDOM instance per request, which we avoid entirely here.
    // Mozilla Readability already strips dangerous markup from its output.
    dom = new JSDOM(html, {
      url,
      virtualConsole,
      // runScripts defaults to 'outside-only' — no inline/external scripts run
    });

    const reader = new Readability(dom.window.document);
    const article = reader.parse();

    if (!article) {
      return res.status(422).json({ error: 'Could not extract readable content from URL' });
    }

    res.json({
      url,
      title: article.title ?? null,
      byline: article.byline ?? null,
      content: article.content ?? null,
      excerpt: article.excerpt ?? null,
      length: article.length ?? 0,
      dir: article.dir ?? null,
      siteName: article.siteName ?? null,
    });

  } catch (err) {
    if (err.name === 'AbortError') {
      return res.status(504).json({ error: `Request timed out after ${FETCH_TIMEOUT_MS}ms` });
    }
    console.error(`[readability] Error processing "${url}":`, err.message);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Internal server error' });
    }
  } finally {
    // Critical: always close the JSDOM window to release the DOM tree,
    // event listeners, and all associated V8 heap objects.
    // Without this, each request permanently grows the heap.
    if (dom) {
      dom.window.close();
      dom = null;
    }
  }
});

const server = app.listen(PORT, () => {
  console.log(`[readability] Server listening on port ${PORT}`);
});

function shutdown(signal) {
  console.log(`[readability] Received ${signal}, shutting down gracefully...`);
  server.close(() => {
    console.log('[readability] HTTP server closed');
    process.exit(0);
  });
  // Force exit if in-flight requests don't drain within 10 s
  setTimeout(() => {
    console.error('[readability] Forced exit after 10s shutdown timeout');
    process.exit(1);
  }, 10_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('uncaughtException', (err) => {
  console.error('[readability] Uncaught exception:', err);
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  console.error('[readability] Unhandled rejection:', reason);
});
