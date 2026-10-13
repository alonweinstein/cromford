import { defineConfig } from 'vite';
import { themeBootPlugin } from './src/theme/boot.js';

// Everything ships self-contained: no CDN scripts, no external stylesheets, the
// fonts are woff2s in public/fonts. `functions/` is Cloudflare Pages' own
// directory and must NOT be bundled — it is copied to the deploy root as-is.
export default defineConfig({
  base: '/',
  // Writes the theme onto :root from an inline <head> script, before the
  // stylesheet paints (BH-4844, src/theme/boot.js).
  plugins: [themeBootPlugin()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    assetsInlineLimit: 0
  },
  server: {
    port: 5180,
    // `npm run dev` talks to the deployed worker directly. The Pages Functions
    // proxy is what makes production same-origin; this is its dev twin.
    proxy: {
      '/api': { target: 'https://harness-console.operator.workers.dev', changeOrigin: true },
      '/login': { target: 'https://harness-console.operator.workers.dev', changeOrigin: true }
    }
  }
});
