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

// Large-image feedback must be warning-only at the agreed 4M-pixel boundary.
const showFileStart = html.indexOf("function showFile(f){");
const showFileEnd = html.indexOf("$('#file').onchange", showFileStart);
if (showFileStart < 0 || showFileEnd < 0) throw new Error("could not locate showFile() for image-size regression checks");
const showFileSource = html.slice(showFileStart, showFileEnd);
function selectImage(width, height) {
  const nodes = {
    "#afterImg": { removeAttribute() {} },
    "#stage": {},
    "#empty": {},
    "#compare": { classList: { add() {} } },
    "#run": {},
    "#fileMeta": {},
  };
  const context = {
    busy: false, resultReady: false, resultUrl: null, file: null, largeImage: false,
    imageReady: false, w: 0, h: 0, srcUrl: null, alphaCanvas: null,
    tr: (key) => key,
    status: (key, kind) => { context.statusMessage = { key, kind }; },
    $: (selector) => nodes[selector] || {},
    URL: { createObjectURL: () => "blob:fixture", revokeObjectURL() {} },
    Image: class {
      constructor() { this.width = width; this.height = height; }
      set src(_value) { this.onload(); }
    },
    document: {
      createElement: () => ({ width: 0, height: 0, getContext: () => ({ drawImage() {} }) }),
    },
  };
  vm.createContext(context);
  vm.runInContext(showFileSource, context);
  context.showFile({ type: "image/png", name: "fixture.png" });
  return { context, run: nodes["#run"] };
}
const belowWarning = selectImage(1999, 2000);
if (belowWarning.context.statusMessage?.key !== "imageReady" || belowWarning.run.disabled) {
  throw new Error("images below 4M pixels should be accepted without a size warning");
}
const wideBelowWarning = selectImage(5000, 500);
if (wideBelowWarning.context.statusMessage?.key !== "imageReady" || wideBelowWarning.run.disabled) {
  throw new Error("a long edge above 4096px alone must not trigger a size warning or block");
}
for (const [width, height] of [[2000, 2000], [5000, 1000]]) {
  const selection = selectImage(width, height);
  if (selection.context.statusMessage?.key !== "imageTooLarge" || selection.run.disabled || !selection.context.imageReady) {
    throw new Error(`${width}x${height} must show a warning but remain ready to upscale`);
  }
}
if (!html.includes("if(statusKey)status(statusKey,statusKind,statusValues)")) {
  throw new Error("the current status must be retranslated after changing the page language");
}

function runtimeStatusTable(source) {
  const start = source.indexOf("// Runtime status messages");
  const end = source.indexOf("\n};", start);
  if (start < 0 || end < 0) throw new Error("missing runtime status translation table");
  return source.slice(start, end + 3);
}
if (runtimeStatusTable(html) !== runtimeStatusTable(extraTranslations)) {
  throw new Error("runtime status translations in index.html and i18n.js are out of sync");
}

// The status table must EXTEND each locale table. Assigning a status-only object
// over a locale (Object.assign(T, {en:{...}})) silently deletes that locale's
// page copy, so every label turns into its raw translation key on the next
// render() - which a style or preference click triggers.
const baseT = vm.runInNewContext("(" + baseMatch[1] + ")", {});
const baseKeys = Object.keys(baseT.en).sort();
const pageRoot = loadPage("https://4x.pixcc.net/");
for (const locale of locales) {
  const lost = baseKeys.filter((key) => pageRoot.T[locale][key] === undefined);
  if (lost.length) {
    throw new Error(`locale ${locale} lost its page copy after the status merge: ${lost.join(", ")}`);
  }
}
// The runtime status keys must arrive as a standalone table that is merged per
// locale, never as Object.assign(T, {en:{...}}) which replaces those locales.
for (const [name, source] of [["web/index.html", html], ["web/i18n.js", extraTranslations]]) {
  const block = runtimeStatusTable(source);
  if (!block.includes("const S = {")) {
    throw new Error(`${name} must build the runtime status table as its own object`);
  }
}

// Clicking a style or preference re-runs render() for every [data-t] node. Run
// that exact function in zh-Hans and require real copy, not raw keys.
const renderSource = html.match(/function render\(\)\{[\s\S]*?\}const LOCALES/)[0].replace(/\}const LOCALES$/, "}");
const painted = [];
const renderContext = vm.createContext({
  T: pageRoot.T, lang: "zh-Hans", resultReady: false, file: null,
  statusKey: "", statusKind: "", statusValues: {},
  tr: (key) => pageRoot.T["zh-Hans"][key] ?? pageRoot.T.en[key] ?? key,
  status: () => {},
  document: { documentElement: {} },
  history: { replaceState: () => {} },
  $: () => ({ value: "" }),
  $$: () => ["settings", "photo", "start", "title"].map((key) => ({
    id: `node-${key}`, dataset: { t: key }, set innerHTML(value) { painted.push([key, value]); },
  })),
});
vm.runInContext(renderSource + "render();", renderContext);
if (!painted.length) throw new Error("render() painted no [data-t] nodes; the check cannot vouch for them");
for (const [key, value] of painted) {
  if (value === key || value === undefined || value === "") {
    throw new Error(`after switching style/preference, "${key}" rendered as its raw key instead of localized copy`);
  }
}
if (!painted.some(([, value]) => /[\u4e00-\u9fff]/.test(value))) {
  throw new Error("after switching style/preference, the page copy was not Chinese");
}
const warningStatusNode = { textContent: "", className: "" };
const statusSource = html.slice(html.indexOf("function status("), html.indexOf("function statusErrorKey"));
const statusContext = vm.createContext({
  T: root.T, lang: "en", statusKey: "", statusKind: "", statusValues: {},
  $: () => warningStatusNode,
});
statusContext.tr = (key) => statusContext.T[statusContext.lang]?.[key] || statusContext.T.en[key] || key;
vm.runInContext(statusSource, statusContext);
statusContext.status("imageTooLarge", "warn");
const englishWarning = warningStatusNode.textContent;
statusContext.lang = "zh-Hans";
statusContext.status(statusContext.statusKey, statusContext.statusKind, statusContext.statusValues);
if (!englishWarning.includes("large") || warningStatusNode.textContent === englishWarning || !warningStatusNode.textContent.includes("图片")) {
  throw new Error("large-image warning did not follow the currently selected language");
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
  progressPct: 0,
  status: (key, kind = "", values = {}) => { statusNode.textContent = key === "upscalingProgress" ? `Upscaling locally… ${values.percent}%` : key; statusNode.className = kind; },
  console,
});
const progressSource = html.match(/function progress\([^\n]*?\}function selected/);
if (!progressSource) throw new Error("could not locate progress() in web/index.html");
vm.runInContext(progressSource[0].replace(/function selected$/, ""), callbackContext);
const cpuCallbackSource = html.match(/function cpuCallback\(x\)\{[^\n]*?\}async function loadWasm/);
if (!cpuCallbackSource) throw new Error("could not locate cpuCallback() in web/index.html");
vm.runInContext(cpuCallbackSource[0].replace(/async function loadWasm$/, ""), callbackContext);
// The reported percentage must be the one drawn on the bar. Reporting the raw
// stage rate beside a bar that already includes the download share showed "1%"
// next to a bar that was a quarter full.
for (const rate of [0.01, 0.62, 1]) {
  callbackContext.cpuCallback(JSON.stringify({ eventType: "PROC_PROGRESS", progress_rate: rate }));
  const barPercent = parseFloat(bar.style.width);
  if (barPercent !== 25 + 75 * rate) {
    throw new Error(`CPU progress callback set ${bar.style.width || "no width"}, expected ${25 + 75 * rate}% at rate ${rate}`);
  }
  const shown = Number((statusNode.textContent.match(/(\d+)%/) || [])[1]);
  if (shown !== Math.ceil(barPercent)) {
    throw new Error(`progress text says ${shown}% while the bar is at ${barPercent}%`);
  }
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
