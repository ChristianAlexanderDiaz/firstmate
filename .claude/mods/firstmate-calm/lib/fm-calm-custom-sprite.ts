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

/**
 * Whether a code point draws as exactly one terminal column. Controls, combining marks,
 * zero-width and variation selectors, and the East Asian wide and emoji ranges are
 * refused, because a glyph of any other width would break the row's exact fit.
 */
function isSingleColumn(codePoint: number): boolean {
  if (codePoint < 0x20 || (codePoint >= 0x7f && codePoint < 0xa0)) return false;
  const refused: readonly (readonly [number, number])[] = [
    [0x0300, 0x036f], [0x0483, 0x0489], [0x0591, 0x05bd], [0x0610, 0x061a],
    [0x064b, 0x065f], [0x1100, 0x115f], [0x1ab0, 0x1aff], [0x1dc0, 0x1dff],
    [0x200b, 0x200f], [0x2028, 0x202e], [0x2060, 0x206f], [0x20d0, 0x20ff],
    [0x231a, 0x231b], [0x23e9, 0x23f3], [0x25fd, 0x25fe], [0x2614, 0x2615],
    [0x2648, 0x2653], [0x26aa, 0x26ab], [0x26bd, 0x26be], [0x26c4, 0x26c5],
    [0x2705, 0x2705], [0x270a, 0x270b], [0x2728, 0x2728], [0x274c, 0x274c],
    [0x2753, 0x2757], [0x2795, 0x2797], [0x27b0, 0x27b0], [0x2b1b, 0x2b1c],
    [0x2b50, 0x2b50], [0x2b55, 0x2b55], [0x2e80, 0xa4cf], [0xa960, 0xa97f],
    [0xac00, 0xd7a3], [0xd800, 0xdfff], [0xf900, 0xfaff], [0xfe00, 0xfe0f],
    [0xfe10, 0xfe19], [0xfe20, 0xfe6f], [0xfeff, 0xfeff], [0xff00, 0xff60],
    [0xffe0, 0xffe6], [0x1f000, 0x10ffff],
  ];
  return !refused.some(([low, high]) => codePoint >= low && codePoint <= high);
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
      return `${where}[${index}] is ${cells.length} characters wide, not the declared width ${width}`;
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
      if (!isSingleColumn(glyph.codePointAt(0) ?? 0)) {
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
