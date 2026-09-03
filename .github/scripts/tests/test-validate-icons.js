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

"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const { validateIcon } = require("../validate-icons.js");

function errorsFor(icon) {
  return validateIcon(icon, Buffer.byteLength(icon));
}

test("accepts a static SVG with an intra-document mask", () => {
  const icon =
    '<svg xmlns="http://www.w3.org/2000/svg">' +
    '<mask id="icon"><path fill="white"/></mask>' +
    '<rect fill="currentColor" mask="url(#icon)"/>' +
    "</svg>";

  assert.deepEqual(errorsFor(icon), []);
});

test("rejects style elements regardless of case or namespace", () => {
  for (const icon of [
    "<svg><style>.icon { fill: red; }</style></svg>",
    "<svg><STYLE>.icon { fill: red; }</STYLE></svg>",
    "<svg><svg:style>.icon { fill: red; }</svg:style></svg>",
  ]) {
    assert.match(errorsFor(icon).join("\n"), /<style> element/);
  }
});

test("rejects style attributes on root and child elements", () => {
  for (const icon of [
    '<svg style="fill:red"/>',
    '<svg STYLE = "fill:red"/>',
    '<svg><path svg:style="fill:red"/></svg>',
  ]) {
    assert.match(errorsFor(icon).join("\n"), /style attribute/);
  }
});

test("rejects active content and external references", () => {
  const cases = [
    ["<svg><script/></svg>", /<script> element/],
    ['<svg onload="run()"/>', /event-handler attribute/],
    ["<svg><foreignObject/></svg>", /<foreignobject> element/],
    ["<svg><animate/></svg>", /animation element/],
    ['<svg><image href="https://example.invalid/icon"/></svg>', /external resource/],
    ['<svg><rect fill="url(https://example.invalid/paint)"/></svg>', /external resource/],
  ];

  for (const [icon, expected] of cases) {
    assert.match(errorsFor(icon).join("\n"), expected);
  }
});

test("rejects empty and oversized icons", () => {
  assert.match(errorsFor("").join("\n"), /icon is empty/);

  const oversized = `<svg>${" ".repeat(32 * 1024)}</svg>`;
  assert.match(errorsFor(oversized).join("\n"), /exceeds the 32768 byte limit/);
});
