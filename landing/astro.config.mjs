import { defineConfig } from 'astro/config';

// 4321 lo usa la bienvenida del servidor; esta landing va en 4322.
export default defineConfig({
  server: { port: 4322, host: true, allowedHosts: ['ai-workspace', '.ts.net'] },
  devToolbar: { enabled: false },
});
