import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("web/index.html", "utf8");
const extraTranslations = fs.readFileSync("web/i18n.js", "utf8");

// Every page must be self-contained: the build inlines the extra locales, so the
// source has to carry the base table and the shared i18n module must not be
// loaded over the network.
const baseMatch = html.match(/const T=(\{[^\n]*\});/);
if (!baseMatch) throw new Error("web/index.html must define the base inline T table");
if (!html.includes("Object.assign(T,")) {
  throw new Error("web/index.html must inline web/i18n.js (Object.assign(T, {...}))");
}
if (/src="[^"]*i18n\.js"/.test(html)) {
  throw new Error("i18n.js must be inlined, not loaded as a separate script");
}

// The inlined copy in index.html must stay byte-identical to web/i18n.js, or the
// prerendered locale pages and the runtime would disagree.
const inlined = html.match(/Object\.assign\(T, \{[\s\S]*?\n\}\);/);
if (!inlined) throw new Error("could not locate the inlined translation table");
const sourceTable = extraTranslations.match(/Object\.assign\(T, \{[\s\S]*?\n\}\);/);
if (!sourceTable) throw new Error("could not locate the table in web/i18n.js");
if (inlined[0] !== sourceTable[0]) {
  throw new Error("the inlined translation table is out of sync with web/i18n.js");
}

// Load the page's own base table the way a browser does, then let i18n.js extend
// it and pick the route locale.
function loadPage(locationHref) {
  const context = {
    T: vm.runInNewContext("(" + baseMatch[1] + ")", {}),
    lang: "en",
    location: { pathname: new URL(locationHref).pathname, href: locationHref },
    performance: { getEntriesByType: () => [{ name: locationHref }] },
    URL,
    document: { getElementById: () => ({ value: "" }) },
    render: () => {},
  };
  vm.createContext(context);
  vm.runInContext(extraTranslations, context);
  return context;
}

const locales = ["en", "zh-Hans", "zh-Hant", "fr", "de", "es", "pt", "ar", "ru", "ja", "ko"];
const root = loadPage("https://4x.pixcc.net/");
const reference = Object.keys(root.T.en).sort();
for (const locale of locales) {
  const table = root.T[locale];
  if (!table) throw new Error(`Missing translation: ${locale}`);
  const missing = reference.filter((key) => table[key] === undefined);
  if (missing.length) {
    throw new Error(`Incomplete translation ${locale}: missing ${missing.join(", ")}`);
  }
}

// A direct locale route must retain its language instead of falling back to root.
const fr = loadPage("https://4x.pixcc.net/fr/");
if (fr.lang !== "fr") throw new Error(`Direct locale route /fr/ resolved to ${fr.lang}`);

if ((html.match(/seamile\/realesrgan-wasm/g) || []).length !== 2) {
  throw new Error("The project link should appear only in navigation and footer");
}

// The result preview/download must never be left wired to a stale button handler.
for (const needle of ["function onRunClick()", "function resetResult()", "$('#run').onclick=onRunClick;"]) {
  if (!html.includes(needle)) throw new Error(`web/index.html is missing ${needle}`);
}
if (html.includes("$('#run').onclick=()=>{")) {
  throw new Error("display() must not hijack the run button with its own download handler");
}

// progress() must tolerate calls without an explicit window, otherwise the
// width is computed from an undefined base and evaluates to NaN% (no-op).
if (!/function progress\(n,base,span\)\{const b=base===undefined\?0:base;/.test(html)) {
  throw new Error("progress() must default an omitted base to 0");
}

// $() returns one element; only the $$() helper returns an array. Match a
// single dollar that is not preceded by another dollar.
const forEachBug = html.match(/(?<!\$)\$\([^)]*\)\.forEach\(/);
if (forEachBug) {
  throw new Error(`single-element $() used with .forEach(): ${forEachBug[0]}`);
}

// The progress label and visual bar must advance from the same CPU callback.
const bar = { style: {} };
const statusNode = { textContent: "", className: "" };
const callbackContext = vm.createContext({
  $: (selector) => selector === "#bar" ? bar : statusNode,
  doneResolve: null,
  DOWNLOAD_SHARE: 0.25,
  status: (text, kind = "") => { statusNode.textContent = text; statusNode.className = kind; },
  console,
});
const progressSource = html.match(/function progress\([^\n]*?\}function selected/);
if (!progressSource) throw new Error("could not locate progress() in web/index.html");
vm.runInContext(progressSource[0].replace(/function selected$/, ""), callbackContext);
const cpuCallbackSource = html.match(/function cpuCallback\(x\)\{[^\n]*?\}async function loadWasm/);
if (!cpuCallbackSource) throw new Error("could not locate cpuCallback() in web/index.html");
vm.runInContext(cpuCallbackSource[0].replace(/async function loadWasm$/, ""), callbackContext);
callbackContext.cpuCallback(JSON.stringify({ eventType: "PROC_PROGRESS", progress_rate: 0.62 }));
if (parseFloat(bar.style.width) !== 71.5) {
  throw new Error(`CPU progress callback set ${bar.style.width || "no width"}, expected 71.5% at 62%`);
}
if (!statusNode.textContent.includes("62%")) {
  throw new Error("CPU progress callback did not update the matching progress label");
}

// The comparison must expose a full-stage drag surface. A range input with no
// height only occupies the browser's default-sized strip at the stage bottom.
const visualRegressionFailures = [];
const sliderCss = html.match(/\.compare input\{([^}]*)\}/)?.[1] || "";
if (!/(?:inset:0(?:;|$)|height:100%)/.test(sliderCss)) {
  visualRegressionFailures.push("comparison slider hit area does not cover the preview stage");
}

// The 4× image must be scaled into the same display box as the original rather
// than rendered at its intrinsic dimensions and clipped to the top-left.
const beforeImageCss = html.match(/\.compare img\{([^}]*)\}/)?.[1] || "";
const afterImageCss = html.match(/\.compare \.after img\{([^}]*)\}/)?.[1] || "";
if (!/width:100%/.test(afterImageCss) || !/height:100%/.test(afterImageCss)) {
  visualRegressionFailures.push("comparison images do not share the same displayed dimensions");
}
if (!/object-fit:contain/.test(beforeImageCss) || !/object-fit:contain/.test(afterImageCss)) {
  visualRegressionFailures.push("original and result must preserve their aspect ratios inside the preview");
}
const stageCss = html.match(/\.compare-inner\{([^}]*)\}/)?.[1] || "";
if (!/background:#f5f5f5/.test(stageCss)) {
  visualRegressionFailures.push("transparent image areas must not reveal the dark preview background");
}
if (html.includes('<div class="labels">')) {
  visualRegressionFailures.push("comparison labels should not be rendered in the preview");
}
if (/\.labels(?: span)?\{/.test(html)) {
  visualRegressionFailures.push("obsolete comparison-label styling should be removed");
}
const sliderMapping = html.match(/\$\('#slider'\)\.oninput=e=>\{([^}]*)\}/)?.[1] || "";
if (!sliderMapping.includes("$('#divider').style.left=e.target.value+'%'") ||
    !sliderMapping.includes("$('#after').style.clipPath='inset(0 0 0 '+e.target.value+'%)'")) {
  visualRegressionFailures.push("slider must reveal the result to the right of the original");
}
if (visualRegressionFailures.length) {
  throw new Error(visualRegressionFailures.join("; "));
}

console.log("web UI checks passed");
