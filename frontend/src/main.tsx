import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Theme } from "@astryxdesign/core/theme";
import { ToastViewport } from "@astryxdesign/core/Toast";

import "@astryxdesign/core/reset.css";
import "@astryxdesign/core/astryx.css";
import "./index.css";

import App from "./App";
import { logixTheme } from "./theme";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Theme theme={logixTheme}>
      <ToastViewport>
        <App />
      </ToastViewport>
    </Theme>
  </StrictMode>,
);
