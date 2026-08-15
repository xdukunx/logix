import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "./tokens.css";
import "./index.css";

import App from "./App";
import { ThemeModeProvider } from "./theme/ThemeMode";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ThemeModeProvider>
      <App />
    </ThemeModeProvider>
  </StrictMode>,
);
