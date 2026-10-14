import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import "@/i18n/config";
import App from "@/app/App";
import { ThemeProvider } from "@/components/theme-provider";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ThemeProvider
      attribute="class"
      defaultTheme="light"
      enableSystem={false}
      storageKey="skopos.theme"
      disableTransitionOnChange
    >
      <App />
    </ThemeProvider>
  </StrictMode>,
);
