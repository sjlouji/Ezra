import path from "path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  define: { "process.env.NODE_ENV": '"production"' },
  build: {
    outDir: "kit-out", emptyOutDir: false, minify: true,
    lib: { entry: "src/kit.tsx", name: "EzraKit", formats: ["iife"], fileName: () => "kit.js" },
  },
});
