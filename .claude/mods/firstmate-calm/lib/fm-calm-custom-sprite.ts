// Parses the captain's optional local Calm sprite, gitignored `config/calm-sprite.json`.
//
// docs/configuration.md owns the file's schema and docs/calm.md the captain-facing
// behavior; ./fm-calm-working-ship-sprite.ts owns how a parsed sprite is drawn. This
// module only turns the file's text into a validated CalmCustomSprite, or a reason it
// cannot, so every failure leaves the caller on the stock boat. It is pure and imports
// no harness, so tests run it under Node and either harness could adopt it.
import type {
  CalmCustomSprite,
  CalmCustomSpriteCell,
  CalmCustomSpriteFrame,
} from "./fm-calm-working-ship-sprite.ts";

/** The only schema version this parser reads. */
export const CALM_CUSTOM_SPRITE_VERSION = 1;
/** Widest sprite accepted, in terminal columns. */
export const CALM_CUSTOM_SPRITE_MAX_WIDTH = 64;
/** Most frames accepted. */
export const CALM_CUSTOM_SPRITE_MAX_FRAMES = 8;
/** Largest file accepted, in characters, so a stray large file is refused cheaply. */
export const CALM_CUSTOM_SPRITE_MAX_CHARS = 65536;

export type CalmCustomSpriteParse =
  | { readonly ok: true; readonly sprite: CalmCustomSprite }
  | { readonly ok: false; readonly reason: string };

// Glyphs that swap with a partner when a frame is mirrored to face left. Any glyph not
// listed mirrors onto itself.
const MIRROR_PAIRS: readonly (readonly [string, string])[] = [
  ["▌", "▐"], ["▖", "▗"], ["▘", "▝"], ["▙", "▟"], ["▛", "▜"], ["▚", "▞"],
  ["◢", "◣"], ["◤", "◥"], ["◸", "◹"], ["◺", "◿"], ["◀", "▶"], ["◁", "▷"],
  ["╱", "╲"], ["/", "\\"], ["(", ")"], ["[", "]"], ["{", "}"], ["<", ">"],
  ["╭", "╮"], ["╰", "╯"], ["┌", "┐"], ["└", "┘"], ["├", "┤"],
];
const MIRROR = new Map<string, string>(
  MIRROR_PAIRS.flatMap(([a, b]) => [[a, b], [b, a]] as const),
);

// Every East Asian Wide (W) and Fullwidth (F) range in Unicode 16.0 EastAsianWidth.txt,
// which is what terminals draw two columns wide, including emoji presentation symbols
// such as U+26A1. Ranges are inclusive and sorted, so a binary search finds a match.
const WIDE_RANGES: readonly (readonly [number, number])[] = [
  [0x1100, 0x115f], [0x231a, 0x231b], [0x2329, 0x232a], [0x23e9, 0x23ec],
  [0x23f0, 0x23f0], [0x23f3, 0x23f3], [0x25fd, 0x25fe], [0x2614, 0x2615],
  [0x2630, 0x2637], [0x2648, 0x2653], [0x267f, 0x267f], [0x268a, 0x268f],
  [0x2693, 0x2693], [0x26a1, 0x26a1], [0x26aa, 0x26ab], [0x26bd, 0x26be],
  [0x26c4, 0x26c5], [0x26ce, 0x26ce], [0x26d4, 0x26d4], [0x26ea, 0x26ea],
  [0x26f2, 0x26f3], [0x26f5, 0x26f5], [0x26fa, 0x26fa], [0x26fd, 0x26fd],
  [0x2705, 0x2705], [0x270a, 0x270b], [0x2728, 0x2728], [0x274c, 0x274c],
  [0x274e, 0x274e], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797],
  [0x27b0, 0x27b0], [0x27bf, 0x27bf], [0x2b1b, 0x2b1c], [0x2b50, 0x2b50],
  [0x2b55, 0x2b55], [0x2e80, 0x2e99], [0x2e9b, 0x2ef3], [0x2f00, 0x2fd5],
  [0x2ff0, 0x303e], [0x3041, 0x3096], [0x3099, 0x30ff], [0x3105, 0x312f],
  [0x3131, 0x318e], [0x3190, 0x31e5], [0x31ef, 0x321e], [0x3220, 0x3247],
  [0x3250, 0xa48c], [0xa490, 0xa4c6], [0xa960, 0xa97c], [0xac00, 0xd7a3],
  [0xf900, 0xfaff], [0xfe10, 0xfe19], [0xfe30, 0xfe52], [0xfe54, 0xfe66],
  [0xfe68, 0xfe6b], [0xff01, 0xff60], [0xffe0, 0xffe6], [0x16fe0, 0x16fe4],
  [0x16ff0, 0x16ff1], [0x17000, 0x187f7], [0x18800, 0x18cd5], [0x18cff, 0x18d08],
  [0x1aff0, 0x1aff3], [0x1aff5, 0x1affb], [0x1affd, 0x1affe], [0x1b000, 0x1b122],
  [0x1b132, 0x1b132], [0x1b150, 0x1b152], [0x1b155, 0x1b155], [0x1b164, 0x1b167],
  [0x1b170, 0x1b2fb], [0x1d300, 0x1d356], [0x1d360, 0x1d376], [0x1f004, 0x1f004],
  [0x1f0cf, 0x1f0cf], [0x1f18e, 0x1f18e], [0x1f191, 0x1f19a], [0x1f200, 0x1f202],
  [0x1f210, 0x1f23b], [0x1f240, 0x1f248], [0x1f250, 0x1f251], [0x1f260, 0x1f265],
  [0x1f300, 0x1f320], [0x1f32d, 0x1f335], [0x1f337, 0x1f37c], [0x1f37e, 0x1f393],
  [0x1f3a0, 0x1f3ca], [0x1f3cf, 0x1f3d3], [0x1f3e0, 0x1f3f0], [0x1f3f4, 0x1f3f4],
  [0x1f3f8, 0x1f43e], [0x1f440, 0x1f440], [0x1f442, 0x1f4fc], [0x1f4ff, 0x1f53d],
  [0x1f54b, 0x1f54e], [0x1f550, 0x1f567], [0x1f57a, 0x1f57a], [0x1f595, 0x1f596],
  [0x1f5a4, 0x1f5a4], [0x1f5fb, 0x1f64f], [0x1f680, 0x1f6c5], [0x1f6cc, 0x1f6cc],
  [0x1f6d0, 0x1f6d2], [0x1f6d5, 0x1f6d7], [0x1f6dc, 0x1f6df], [0x1f6eb, 0x1f6ec],
  [0x1f6f4, 0x1f6fc], [0x1f7e0, 0x1f7eb], [0x1f7f0, 0x1f7f0], [0x1f90c, 0x1f93a],
  [0x1f93c, 0x1f945], [0x1f947, 0x1f9ff], [0x1fa70, 0x1fa7c], [0x1fa80, 0x1fa89],
  [0x1fa8f, 0x1fac6], [0x1face, 0x1fadc], [0x1fadf, 0x1fae9], [0x1faf0, 0x1faf8],
  [0x20000, 0x2fffd], [0x30000, 0x3fffd],
];

// Marks, format characters, surrogates, and unassigned code points draw zero or an
// unpredictable number of columns.
const ZERO_OR_UNKNOWN_WIDTH = /^[\p{Mn}\p{Me}\p{Cf}\p{Cs}\p{Cn}]$/u;

function isWide(codePoint: number): boolean {
  let low = 0;
  let high = WIDE_RANGES.length - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    const [first, last] = WIDE_RANGES[middle]!;
    if (codePoint < first) high = middle - 1;
    else if (codePoint > last) low = middle + 1;
    else return true;
  }
  return false;
}

/**
 * Whether a glyph draws as exactly one terminal column. Controls, combining marks,
 * zero-width and format characters, unassigned code points, and every East Asian wide
 * or fullwidth character, emoji included, are refused, because a glyph of any other
 * width would break the row's exact fit.
 */
function isSingleColumn(glyph: string): boolean {
  const codePoint = glyph.codePointAt(0) ?? 0;
  if (codePoint < 0x20 || (codePoint >= 0x7f && codePoint < 0xa0)) return false;
  return !ZERO_OR_UNKNOWN_WIDTH.test(glyph) && !isWide(codePoint);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Two strings of exactly `width` characters each, or a reason they are not. */
function twoRows(value: unknown, width: number, where: string): string[][] | string {
  if (!Array.isArray(value) || value.length !== 2) return `${where} must be an array of exactly two rows`;
  const rows: string[][] = [];
  for (const [index, row] of value.entries()) {
    if (typeof row !== "string") return `${where}[${index}] must be a string`;
    const cells = Array.from(row);
    if (cells.length !== width) {
      return `${where}[${index}] is ${cells.length} wide, not ${width}`;
    }
    rows.push(cells);
  }
  return rows;
}

function parseFrame(
  value: unknown,
  width: number,
  palette: ReadonlyMap<string, number>,
  where: string,
): CalmCustomSpriteFrame | string {
  if (!isRecord(value)) return `${where} must be an object`;
  for (const key of Object.keys(value)) {
    if (key !== "glyphs" && key !== "fg" && key !== "bg") return `${where} has an unknown field "${key}"`;
  }
  const glyphs = twoRows(value.glyphs, width, `${where}.glyphs`);
  if (typeof glyphs === "string") return glyphs;
  for (const [row, cells] of glyphs.entries()) {
    for (const [column, glyph] of cells.entries()) {
      if (!isSingleColumn(glyph)) {
        return `${where}.glyphs[${row}] column ${column} is not a single-column glyph`;
      }
    }
  }
  const layers: Record<"fg" | "bg", (number | undefined)[][]> = {
    fg: [[], []],
    bg: [[], []],
  };
  for (const layer of ["fg", "bg"] as const) {
    if (value[layer] === undefined) {
      layers[layer] = glyphs.map((cells) => cells.map(() => undefined));
      continue;
    }
    const keys = twoRows(value[layer], width, `${where}.${layer}`);
    if (typeof keys === "string") return keys;
    for (const [row, cells] of keys.entries()) {
      for (const [column, key] of cells.entries()) {
        if (key === " ") {
          layers[layer][row]!.push(undefined);
          continue;
        }
        const color = palette.get(key);
        if (color === undefined) {
          return `${where}.${layer}[${row}] column ${column} names "${key}", which the palette does not define`;
        }
        layers[layer][row]!.push(color);
      }
    }
  }
  const row = (index: 0 | 1): CalmCustomSpriteCell[] =>
    glyphs[index]!.map((glyph, column) => {
      const foreground = layers.fg[index]![column];
      const background = layers.bg[index]![column];
      return {
        glyph,
        transparent: glyph === " " && background === undefined,
        ...(foreground === undefined ? {} : { foreground }),
        ...(background === undefined ? {} : { background }),
      };
    });
  return [row(0), row(1)];
}

function parseFrames(
  value: unknown,
  width: number,
  palette: ReadonlyMap<string, number>,
  where: string,
): CalmCustomSpriteFrame[] | string {
  if (!Array.isArray(value) || value.length === 0 || value.length > CALM_CUSTOM_SPRITE_MAX_FRAMES) {
    return `${where} must be an array of 1 to ${CALM_CUSTOM_SPRITE_MAX_FRAMES} frames`;
  }
  const frames: CalmCustomSpriteFrame[] = [];
  for (const [index, entry] of value.entries()) {
    const frame = parseFrame(entry, width, palette, `${where}[${index}]`);
    if (typeof frame === "string") return frame;
    frames.push(frame);
  }
  return frames;
}

/** A frame turned to face the other way: cells reversed and paired glyphs swapped. */
export function mirrorCalmCustomSpriteFrame(frame: CalmCustomSpriteFrame): CalmCustomSpriteFrame {
  const mirrorRow = (cells: readonly CalmCustomSpriteCell[]): CalmCustomSpriteCell[] =>
    [...cells].reverse().map((cell) => ({ ...cell, glyph: MIRROR.get(cell.glyph) ?? cell.glyph }));
  return [mirrorRow(frame[0]), mirrorRow(frame[1])];
}

/**
 * Parse the text of `config/calm-sprite.json`. Every problem, including invalid JSON,
 * an unknown version or field, a row of the wrong width, an undefined palette key, or a
 * glyph that is not one terminal column, returns a reason instead of a sprite.
 */
export function parseCalmCustomSprite(text: string): CalmCustomSpriteParse {
  const fail = (reason: string): CalmCustomSpriteParse => ({ ok: false, reason });
  if (text.length > CALM_CUSTOM_SPRITE_MAX_CHARS) {
    return fail(`the file is larger than ${CALM_CUSTOM_SPRITE_MAX_CHARS} characters`);
  }
  let document: unknown;
  try {
    document = JSON.parse(text);
  } catch (error) {
    return fail(`the file is not valid JSON (${error instanceof Error ? error.message : String(error)})`);
  }
  if (!isRecord(document)) return fail("the file must hold one JSON object");
  for (const key of Object.keys(document)) {
    if (!["version", "width", "palette", "right"].includes(key)) {
      return fail(`unknown field "${key}"`);
    }
  }
  if (document.version !== CALM_CUSTOM_SPRITE_VERSION) {
    return fail(`"version" must be ${CALM_CUSTOM_SPRITE_VERSION}`);
  }
  const width = document.width;
  if (typeof width !== "number" || !Number.isInteger(width) || width < 1 || width > CALM_CUSTOM_SPRITE_MAX_WIDTH) {
    return fail(`"width" must be an integer from 1 to ${CALM_CUSTOM_SPRITE_MAX_WIDTH}`);
  }
  const palette = new Map<string, number>();
  if (document.palette !== undefined) {
    if (!isRecord(document.palette)) return fail(`"palette" must be an object`);
    for (const [key, color] of Object.entries(document.palette)) {
      if (Array.from(key).length !== 1 || key === " ") {
        return fail(`palette key "${key}" must be one character other than a space`);
      }
      if (typeof color !== "string" || !/^#[0-9a-fA-F]{6}$/.test(color)) {
        return fail(`palette color for "${key}" must be a "#rrggbb" string`);
      }
      palette.set(key, Number.parseInt(color.slice(1), 16));
    }
  }
  const right = parseFrames(document.right, width, palette, `"right"`);
  if (typeof right === "string") return fail(right);
  return { ok: true, sprite: { width, right, left: right.map(mirrorCalmCustomSpriteFrame) } };
}
