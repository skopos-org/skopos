import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import en from "@/i18n/en";
import ja from "@/i18n/ja";

const localeKey = "skopos.locale";
export const supportedLocales = [
  { value: "en", label: "English", resource: en },
  { value: "ja", label: "日本語", resource: ja },
] as const;

export type SupportedLocale = (typeof supportedLocales)[number]["value"];

export function normalizeLocale(locale: string | null | undefined): SupportedLocale {
  const language = locale?.trim().toLocaleLowerCase().split("-")[0];
  return supportedLocales.find((candidate) => candidate.value === language)?.value ?? "en";
}

const storedLocale = localStorage.getItem(localeKey);
const defaultLocale = storedLocale
  ? normalizeLocale(storedLocale)
  : normalizeLocale(navigator.language);

void i18n.use(initReactI18next).init({
  resources: Object.fromEntries(supportedLocales.map(({ value, resource }) => [value, resource])),
  lng: defaultLocale,
  fallbackLng: "en",
  interpolation: { escapeValue: false },
});

i18n.on("languageChanged", (locale) => {
  const supportedLocale = normalizeLocale(locale);
  localStorage.setItem(localeKey, supportedLocale);
  document.documentElement.lang = supportedLocale;
});

document.documentElement.lang = defaultLocale;

export default i18n;
