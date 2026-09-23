import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("web/index.html", "utf8");
const translations = fs.readFileSync("web/i18n.js", "utf8");
const context = {
  T: {},
  lang: "en",
  location: { pathname: "/", href: "https://4x.pixcc.net/" },
  performance: { getEntriesByType: () => [] },
  URL,
  document: { getElementById: () => ({ value: "" }) },
  render: () => {},
};
vm.createContext(context);
vm.runInContext(translations, context);

const locales = ["zh-Hant", "fr", "de", "es", "pt", "ar", "ru", "ja", "ko"];
for (const locale of locales) {
  if (!context.T[locale] || Object.keys(context.T[locale]).length < 30) {
    throw new Error(`Incomplete translation: ${locale}`);
  }
}

const directRouteContext = {
  T: {},
  lang: "en",
  location: { pathname: "/", href: "https://4x.pixcc.net/" },
  performance: { getEntriesByType: () => [{ name: "https://4x.pixcc.net/fr/" }] },
  URL,
  document: { getElementById: () => ({ value: "" }) },
  render: () => {},
};
vm.createContext(directRouteContext);
vm.runInContext(translations, directRouteContext);
if (directRouteContext.lang !== "fr") throw new Error("Direct locale routes must retain their language");

if (!html.includes('src="/i18n.js"')) throw new Error("i18n.js must use a root-relative URL");
if ((html.match(/seamile\/realesrgan-wasm/g) || []).length !== 2) {
  throw new Error("The project link should appear only in navigation and footer");
}
console.log("web UI checks passed");
