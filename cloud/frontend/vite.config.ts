import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      "/api": {
        target: "https://scan-api-839349778883.us-central1.run.app",
        changeOrigin: true,
        secure: true,
      },
      "/quote": {
        target: "https://scan-api-839349778883.us-central1.run.app",
        changeOrigin: true,
        secure: true,
      },
      "/bids": {
        target: "https://scan-api-839349778883.us-central1.run.app",
        changeOrigin: true,
        secure: true,
      },
      "/admin": {
        target: "https://scan-api-839349778883.us-central1.run.app",
        changeOrigin: true,
        secure: true,
      },
    },
  },
  build: {
    outDir: "dist",
    sourcemap: false,
  },
});
