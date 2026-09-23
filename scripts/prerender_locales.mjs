#!/usr/bin/env node
/**
 * Build-time locale prerender for the static site.
 *
 * The runtime already swaps [data-t] text after i18n.js loads. This script
 * additionally bakes the selected language into each generated entry page so
 * crawlers and no-JS visitors see localized <html lang>, <title>, description,
 * canonical/hreflang/Open Graph metadata, JSON-LD and the main body copy.
 *
 * Usage: node scripts/prerender_locales.mjs <versioned-index.html> <i18n.js> <out-dir>
 */
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const [, , indexPath, i18nPath, outDir] = process.argv;
if (!indexPath || !i18nPath || !outDir) {
  console.error("usage: prerender_locales.mjs <versioned-index.html> <i18n.js> <out-dir>");
  process.exit(2);
}

const SITE = "https://4x.pixcc.net";
const LOCALES = ["en", "zh-Hans", "zh-Hant", "fr", "de", "es", "pt", "ar", "ru", "ja", "ko"];
const OG_LOCALE = {
  en: "en_US",
  "zh-Hans": "zh_CN",
  "zh-Hant": "zh_TW",
  fr: "fr_FR",
  de: "de_DE",
  es: "es_ES",
  pt: "pt_PT",
  ar: "ar_AR",
  ru: "ru_RU",
  ja: "ja_JP",
  ko: "ko_KR",
};

const html = fs.readFileSync(indexPath, "utf8");

// Extract the inline base translation table (en + zh-Hans) from index.html.
const baseMatch = html.match(/^const T=(\{.*\});\r?\n/m);
if (!baseMatch) throw new Error("could not find the inline T table in " + indexPath);
// eslint-disable-next-line no-eval
const baseT = eval("(" + baseMatch[1] + ")");

// Load i18n.js the same way the browser does: it appends the other languages.
const context = {
  T: baseT,
  lang: "en",
  location: { pathname: "/", href: SITE + "/" },
  performance: { getEntriesByType: () => [] },
  URL,
  document: { getElementById: () => ({ value: "" }) },
  render: () => {},
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(i18nPath, "utf8"), context);
const T = context.T;

function stripTags(value) {
  return String(value == null ? "" : value)
    .replace(/<br\s*\/?>/gi, " ")
    .replace(/<[^>]*>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
function escapeAttr(value) {
  return escapeHtml(value).replace(/"/g, "&quot;");
}
function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function t(locale, key) {
  const table = T[locale] || {};
  const fallback = T.en || {};
  return table[key] !== undefined ? table[key] : fallback[key] !== undefined ? fallback[key] : key;
}

function hreflangBlock() {
  const self = (locale) => `${SITE}/${locale}/`;
  return (
    LOCALES.map((l) => `<link rel="alternate" hreflang="${l}" href="${self(l)}">`).join("") +
    `<link rel="alternate" hreflang="x-default" href="${SITE}/">`
  );
}

function renderPage(locale, isRoot) {
  const url = isRoot ? `${SITE}/` : `${SITE}/${locale}/`;
  const lang = isRoot ? "en" : locale;
  const title = stripTags(t(lang, "title"));
  const description = stripTags(t(lang, "intro"));
  const dir = lang === "ar" ? ' dir="rtl"' : "";
  const headTitle = `${title || "PIXCC · 4×"} — PIXCC · 4×`;
  const jsonld = JSON.stringify({
    "@context": "https://schema.org",
    "@type": "WebApplication",
    name: "PIXCC · 4×",
    url,
    applicationCategory: "MultimediaApplication",
    operatingSystem: "Web",
    browserRequirements: "Requires a browser with WebAssembly; WebGPU is optional.",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    description,
  });

  let out = html;
  // Head: language + self-referencing canonical + hreflang + social metadata.
  out = out.replace('<html lang="en">', `<html lang="${lang}"${dir}>`);
  out = out.replace(
    /<title>[^<]*<\/title>/,
    `<title>${escapeHtml(headTitle)}</title>`
  );
  out = out.replace(
    /<meta name="description" content="[^"]*">/,
    `<meta name="description" content="${escapeAttr(description)}">`
  );
  out = out.replace(
    /<link rel="canonical" href="[^"]*">/,
    `<link rel="canonical" href="${url}">${hreflangBlock()}<meta property="og:url" content="${url}"><meta property="og:locale" content="${OG_LOCALE[lang] || "en_US"}">`
  );
  out = out.replace(
    /<meta property="og:title" content="[^"]*">/,
    `<meta property="og:title" content="${escapeAttr(title || "PIXCC · 4×")}">`
  );
  out = out.replace(
    /<meta property="og:description" content="[^"]*">/,
    `<meta property="og:description" content="${escapeAttr(description)}">`
  );
  out = out.replace(
    "</head>",
    `<script type="application/ld+json">${jsonld}</script></head>`
  );

  // Body: replace each [data-t] element's content with the locale value.
  for (const key of Object.keys(T.en || {})) {
    const value = t(lang, key);
    const re = new RegExp(
      '(<([a-zA-Z0-9]+)\\b[^>]*\\bdata-t="' +
        escapeRegex(key) +
        '"[^>]*>)([\\s\\S]*?)(</\\2>)',
      "g"
    );
    out = out.replace(re, (match, open, tag, _inner, close) => open + value + close);
  }

  return out;
}

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "index.html"), renderPage("en", true));
for (const locale of LOCALES) {
  const dir = path.join(outDir, locale);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "index.html"), renderPage(locale, false));
}
console.log(`prerendered root + ${LOCALES.length} locale pages`);
