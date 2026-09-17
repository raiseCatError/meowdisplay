import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// Served via GitHub Pages (Pages "deploy from branch" → /docs). Relative base
// keeps asset URLs working under whatever subpath (or custom domain) Pages
// serves from, without hardcoding it, and the build emits straight into
// docs/ so the published folder stays the same.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "docs",
    emptyOutDir: true,
  },
})
