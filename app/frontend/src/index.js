/**
 * index.js — React Application Entry Point
 *
 * WHAT THIS FILE DOES:
 * --------------------
 * This is the FIRST JavaScript file that runs when the browser loads the app.
 * It mounts the entire React component tree into the HTML DOM.
 *
 * BROWSER EXECUTION FLOW:
 * -----------------------
 * 1. Browser loads index.html (served by Nginx in K8s)
 * 2. index.html has: <div id="root"></div>
 * 3. Webpack-bundled main.js (from npm run build) loads
 * 4. index.js runs: ReactDOM.render(<App />, document.getElementById('root'))
 * 5. React mounts the entire component tree into the #root div
 * 6. App.js → componentDidMount → API call to backend → state update → re-render
 *
 * KUBERNETES / NGINX CONTEXT:
 * ---------------------------
 * In the Docker container, Nginx serves the static `build/` directory.
 * The entry point HTML is `build/index.html`.
 * The Nginx `try_files` config ensures that React Router paths (e.g., /tasks)
 * don't 404 — they all serve index.html, and React Router handles routing client-side.
 *
 * REACT 17 NOTE:
 * --------------
 * This app uses React 17 with ReactDOM.render() (legacy API).
 * React 18 uses createRoot() instead:
 *   import { createRoot } from 'react-dom/client';
 *   createRoot(document.getElementById('root')).render(<App />);
 * We keep React 17 to match the reference repo, but note this for production upgrades.
 */

import React from "react";
import ReactDOM from "react-dom";

// Global CSS — applies to the entire application
import "./index.css";

// Root component — the top of our component tree
import App from "./App";

// reportWebVitals — performance measurement tool
// In production, you can send metrics to an endpoint or analytics service.
// For K8s, you could send to a Prometheus pushgateway or custom metrics endpoint.
import reportWebVitals from "./reportWebVitals";

// ─────────────────────────────────────────────────────────────────────────────
// MOUNT REACT APP INTO DOM
// ─────────────────────────────────────────────────────────────────────────────
// React.StrictMode:
//   - Enables additional development-only warnings
//   - Detects deprecated lifecycle methods
//   - Warns about side-effects in the render phase
//   - Does NOT affect production builds (stripped out by webpack)
ReactDOM.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
  // Mount point — matches <div id="root"> in public/index.html
  document.getElementById("root")
);

// ─────────────────────────────────────────────────────────────────────────────
// WEB VITALS (optional performance monitoring)
// ─────────────────────────────────────────────────────────────────────────────
// To send metrics to an analytics endpoint:
//   reportWebVitals(console.log);         // Log to console (development)
//   reportWebVitals(sendToAnalytics);     // Send to your endpoint (production)
// Core Web Vitals measured: LCP, FID, CLS, TTFB, FCP
reportWebVitals();
