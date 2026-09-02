#!/usr/bin/env node
/*
Copyright 2025 The Radius Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Validates checked-in SVG icons against the contract Radius enforces in
// pkg/ucp/datamodel/icon_validation.go. Icons that fail these rules are
// rejected when Radius registers the resource type, which breaks the
// downstream manifest refresh in radius-project/radius. Catching them here
// keeps a bad icon from ever reaching that synchronization.

"use strict";

const fs = require("fs");
const path = require("path");

const MAX_ICON_SIZE_BYTES = 32 * 1024;

const FORBIDDEN_ELEMENTS = new Set(["script", "style", "foreignobject"]);
const SMIL_ELEMENTS = new Set([
  "animate",
  "animatemotion",
  "animatetransform",
  "set",
  "discard",
]);
const URL_BEARING_ATTRS = new Set([
  "fill",
  "stroke",
  "filter",
  "mask",
  "clip-path",
  "marker",
  "marker-start",
  "marker-mid",
  "marker-end",
  "cursor",
]);

function walk(dir) {
  const found = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...walk(full));
    else if (entry.name.toLowerCase().endsWith(".svg")) found.push(full);
  }
  return found;
}

// Minimal scanner over start tags. SVG icons are static documents, so a full
// XML parser is unnecessary; we only need element names and their attributes.
function scanTags(source) {
  const tags = [];
  const withoutComments = source.replace(/<!--[\s\S]*?-->/g, "");
  const tagPattern = /<\s*([A-Za-z_][-\w.:]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
  let match;
  while ((match = tagPattern.exec(withoutComments)) !== null) {
    const attrs = [];
    const attrPattern = /([-\w.:]+)\s*=\s*("([^"]*)"|'([^']*)')/g;
    let attrMatch;
    while ((attrMatch = attrPattern.exec(match[2])) !== null) {
      attrs.push({
        name: attrMatch[1],
        value: attrMatch[3] !== undefined ? attrMatch[3] : attrMatch[4],
      });
    }
    tags.push({ name: match[1], attrs });
  }
  return tags;
}

function localName(name) {
  const colon = name.indexOf(":");
  return (colon < 0 ? name : name.slice(colon + 1)).toLowerCase();
}

function checkHrefValue(element, value, errors) {
  const trimmed = value.trim();
  if (trimmed === "") return;
  if (trimmed.includes("\\")) {
    errors.push(
      `<${element}> href value "${value}" contains a backslash escape; CSS escape sequences are not allowed`
    );
    return;
  }
  if (trimmed.startsWith("#")) return;
  if (trimmed.toLowerCase().startsWith("data:")) return;
  errors.push(
    `<${element}> references external resource "${value}" via href; only data: URLs and intra-document fragments are allowed`
  );
}

function checkUrlBearingValue(element, attr, value, errors) {
  if (value.includes("\\")) {
    errors.push(
      `<${element}> attribute "${attr}" contains a backslash escape "${value}"; CSS escape sequences are not allowed`
    );
    return;
  }
  let remaining = value;
  for (;;) {
    const index = remaining.toLowerCase().indexOf("url(");
    if (index < 0) return;
    const after = remaining.slice(index + 4);
    const close = after.indexOf(")");
    if (close < 0) {
      errors.push(
        `<${element}> attribute "${attr}" has malformed url(...) value "${value}"`
      );
      return;
    }
    let target = after.slice(0, close).trim();
    if (
      target.length >= 2 &&
      ((target.startsWith('"') && target.endsWith('"')) ||
        (target.startsWith("'") && target.endsWith("'")))
    ) {
      target = target.slice(1, -1);
    }
    if (!target.startsWith("#")) {
      errors.push(
        `<${element}> attribute "${attr}" references external resource "${value}" via url(); only intra-document fragments are allowed`
      );
      return;
    }
    remaining = after.slice(close + 1);
  }
}

function validateIcon(source, byteLength) {
  const errors = [];

  if (byteLength === 0) errors.push("icon is empty");
  if (byteLength > MAX_ICON_SIZE_BYTES) {
    errors.push(
      `icon is ${byteLength} bytes, which exceeds the ${MAX_ICON_SIZE_BYTES} byte limit`
    );
  }

  const tags = scanTags(source);
  if (tags.length === 0 || localName(tags[0].name) !== "svg") {
    errors.push("icon root element is not <svg>");
  }

  for (const tag of tags) {
    const element = localName(tag.name);

    if (FORBIDDEN_ELEMENTS.has(element)) {
      errors.push(`icon contains a <${element}> element, which is not allowed`);
    }
    if (SMIL_ELEMENTS.has(element)) {
      errors.push(
        `icon contains a <${element}> animation element, which is not allowed`
      );
    }

    for (const attr of tag.attrs) {
      const name = localName(attr.name);
      if (name.startsWith("on")) {
        errors.push(
          `<${element}> has event-handler attribute "${attr.name}", which is not allowed`
        );
      }
      if (name === "style") {
        errors.push(
          `<${element}> has a style attribute, which is not allowed`
        );
      }
      if (name === "href") checkHrefValue(element, attr.value, errors);
      if (URL_BEARING_ATTRS.has(name)) {
        checkUrlBearingValue(element, attr.name, attr.value, errors);
      }
    }
  }

  return errors;
}

function main() {
  const root = process.argv[2] || process.cwd();
  const icons = walk(root).sort();

  if (icons.length === 0) {
    console.error(`No SVG icons found under ${root}`);
    process.exit(1);
  }

  let failed = 0;
  for (const icon of icons) {
    const relative = path.relative(root, icon).split(path.sep).join("/");
    const buffer = fs.readFileSync(icon);
    const errors = validateIcon(buffer.toString("utf8"), buffer.byteLength);

    if (errors.length === 0) {
      console.log(`ok   ${relative}`);
      continue;
    }

    failed++;
    console.error(`FAIL ${relative}`);
    for (const error of errors) console.error(`       ${error}`);
  }

  console.log(`\n${icons.length} icon(s) checked, ${failed} failed`);
  if (failed > 0) {
    console.error(
      "\nRadius rejects these icons at registration time. See the icon section of\n" +
        "docs/contributing/contributing-resource-types-recipes.md for the supported\n" +
        "mask + currentColor pattern."
    );
    process.exit(1);
  }
}

main();
