import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ToastViewport } from "@astryxdesign/core/Toast";

import "@astryxdesign/core/reset.css";
import "@astryxdesign/core/astryx.css";
import "./tokens.css";
import "./index.css";

import App from "./App";
import { ThemeModeProvider } from "./theme/ThemeMode";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ThemeModeProvider>
      <ToastViewport>
        <App />
      </ToastViewport>
    </ThemeModeProvider>
  </StrictMode>,
);
