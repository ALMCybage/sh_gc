import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const apiTarget = env.VITE_API_TARGET ?? 'http://127.0.0.1:8099'

  return {
    plugins: [react(), tailwindcss()],

    server: {
      port: 5173,
      // Tenants are addressed as acme.localhost:5173 / whiteknight.localhost:5173.
      // Browsers resolve *.localhost to 127.0.0.1 with no hosts-file entry.
      allowedHosts: ['.localhost'],

      /*
       * Proxying /api and /sanctum makes development same-origin, which is worth
       * more than it sounds:
       *   - no CORS configuration anywhere, in dev or prod;
       *   - session cookies behave identically to production (SameSite=Lax,
       *     host-only), so an auth bug cannot hide behind a dev-only setting;
       *   - changeOrigin stays false so Laravel receives the real Host header
       *     and resolves the tenant from the subdomain, exactly as it will
       *     behind the GCP load balancer.
       */
      proxy: {
        '/api': { target: apiTarget, changeOrigin: false, secure: false },
        '/sanctum': { target: apiTarget, changeOrigin: false, secure: false },
      },
    },

    build: {
      outDir: 'dist',
      sourcemap: true,
      // Content-hashed filenames are what make the immutable one-year
      // Cache-Control header on /assets/* safe.
      rollupOptions: {
        output: {
          entryFileNames: 'assets/[name].[hash].js',
          chunkFileNames: 'assets/[name].[hash].js',
          assetFileNames: 'assets/[name].[hash][extname]',
        },
      },
    },
  }
})
