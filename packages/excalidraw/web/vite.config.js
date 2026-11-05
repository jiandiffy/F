import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "../../../ui/desktop/Resources/whiteboard",
    emptyOutDir: true,
    target: "safari15",
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 4096,
  },
});
