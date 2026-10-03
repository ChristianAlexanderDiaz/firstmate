// firstmate-calm under `claude plugin test`: the captain's optional local sprite in
// `config/calm-sprite.json`. It draws in the boat's place with its own colors, faces
// its travel direction through the mirrored frames, steps through its frames once per
// move, reflows on resize, and every failure keeps the stock boat.
import { describe, expect, test, type Engine } from "claude-code/testing";
import { calmCommand, decodeCells, rasterOf, spinner, world } from "./support.ts";

const SAIL = "◿│◣";
const HULL = "╲▁▁▁╱";
const DEFAULT = 0x01000000;
const DARK_WATER = 0x93a5ff;
const BODY = 0x3070f0;
const EYE = 0xf0f0f0;
const SHADE = 0x101010;
const TICK = 220;
const TICKS_PER_MOVE = 4;
const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

// A plain five-cell test creature facing right, with a two-frame walk. Its last column
// is transparent on both rows, so the water shows through beside it.
const RIGHT_WALK = "███▶";
const RIGHT_STEP = "▀██▶";
const SPRITE = JSON.stringify({
  version: 1,
  width: 5,
  palette: { b: "#3070f0", e: "#f0f0f0", k: "#101010" },
  right: [
    { glyphs: ["▗▄▖  ", "███▶ "], fg: ["bbb  ", "bbbe "], bg: ["     ", "   k "] },
    { glyphs: ["▗▄▖  ", "▀██▶ "], fg: ["bbb  ", "bbbe "] },
  ],
});

async function draw($: Engine, columns: number) {
  const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns, rows: 24 })))!;
  return { raster, ...decodeCells(raster.cells, raster.columns, raster.rows) };
}

describe("the captain's custom sprite", () => {
  test("draws in the boat's place with its own foregrounds, backgrounds, and water through transparent cells", async ($, on) => {
    world(on, { preference: "on\n", sprite: SPRITE });
    const { raster, glyphs, foregrounds, backgrounds } = await draw($, 40);
    expect(raster.columns).toBe(38);
    expect(raster.rows).toBe(2);
    expect(glyphs[0]!.startsWith("▗▄▖  ")).toBe(true);
    expect(glyphs[1]!.startsWith(RIGHT_WALK)).toBe(true);
    expect(glyphs.join("")).not.toContain(SAIL);
    expect(glyphs.join("")).not.toContain(HULL);
    expect(foregrounds[0]!.slice(0, 3)).toEqual([BODY, BODY, BODY]);
    expect(foregrounds[0]!.slice(3).every((color) => color === DEFAULT)).toBe(true);
    expect(foregrounds[1]!.slice(0, 4)).toEqual([BODY, BODY, BODY, EYE]);
    expect(backgrounds[1]![3]).toBe(SHADE);
    expect(backgrounds[1]!.filter((color) => color !== DEFAULT)).toHaveLength(1);
    // The transparent fifth column and everything past it is water.
    expect(glyphs[1]!.slice(4)).toMatch(/^[▁▂▃▄]+$/);
    expect(foregrounds[1]!.slice(4).every((color) => color === DARK_WATER)).toBe(true);
  });

  test("travels right facing right, turns at the edge, and travels left facing left on the same cadence", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", sprite: SPRITE });
    await $.session.start(sessionStart);
    // Ten columns leave a five-column track: five moves right, then five moves left.
    await draw($, 12);
    const seen: { row0: string; row1: string }[] = [];
    for (let move = 1; move <= 10; move += 1) {
      await clock.advance(TICK * TICKS_PER_MOVE);
      const frame = decodeCells(journal.blits.at(-1)!.cells, 10, 2);
      seen.push({ row0: frame.glyphs[0]!, row1: frame.glyphs[1]! });
    }
    expect(journal.blits).toHaveLength(10 * TICKS_PER_MOVE);
    // Moving right: the head leads at column position + 3, and the walk alternates frames.
    expect(seen[0]!.row1.indexOf(RIGHT_STEP)).toBe(1);
    expect(seen[1]!.row1.indexOf(RIGHT_WALK)).toBe(2);
    expect(seen[3]!.row1.indexOf(RIGHT_WALK)).toBe(4);
    expect(seen[0]!.row0.indexOf("▗▄▖")).toBe(1);
    // Landing on the right edge turns it around: the mirrored frame faces left.
    expect(seen[4]!.row1.slice(5)).toMatch(/^[▁▂▃▄]◀██▀$/);
    expect(seen[4]!.row0.slice(5)).toBe("  ▗▄▖");
    expect(seen[4]!.row1).not.toContain("▶");
    // Moving left: the head leads on the left, one column further each move.
    expect(seen[5]!.row1.indexOf("◀███")).toBe(5);
    expect(seen[6]!.row1.indexOf("◀██▀")).toBe(4);
    expect(seen[8]!.row1.indexOf("◀██▀")).toBe(2);
    // Back at the left edge it faces right again.
    expect(seen[9]!.row1.indexOf(RIGHT_WALK)).toBe(0);
  });

  test("reflows on resize, falls back to the stock boat's narrow shapes below its width, and returns when there is room", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", sprite: SPRITE });
    await $.session.start(sessionStart);
    await draw($, 80);
    await clock.advance(TICK * TICKS_PER_MOVE * 9);
    expect(decodeCells(journal.blits.at(-1)!.cells, 78, 2).glyphs[1]!.indexOf(RIGHT_STEP)).toBe(9);
    // Shrinking clamps it to the new track without wrapping.
    const shrunk = await draw($, 12);
    expect(shrunk.raster.columns).toBe(10);
    expect(shrunk.glyphs[1]!.slice(5)).toMatch(/^[▁▂▃▄]◀██▀$/);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ columns: 10, rows: 2 });
    // Four columns cannot hold five cells: the stock boat's sail-only fallback draws.
    const narrow = await draw($, 6);
    expect(narrow.raster.columns).toBe(4);
    expect(narrow.raster.rows).toBe(1);
    expect(narrow.glyphs[0]).toContain(SAIL);
    // Room again: the creature is back, still facing the way it travels.
    const wide = await draw($, 40);
    expect(wide.raster.rows).toBe(2);
    expect(wide.glyphs[1]).toMatch(/◀██[█▀]/);
  });

  function expectStockBoat(glyphs: string[]) {
    expect(glyphs[0]!.indexOf(SAIL)).toBe(1);
    expect(glyphs[1]!.indexOf(HULL)).toBe(0);
  }

  test("an absent file draws the stock boat silently", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    await $.session.start(sessionStart);
    expectStockBoat((await draw($, 40)).glyphs);
    expect(journal.toasts).toHaveLength(0);
  });

  test("an unreadable file draws the stock boat silently", async ($, on) => {
    const { journal } = world(on, { preference: "on\n", sprite: SPRITE, spriteUnreadable: "EACCES: permission denied" });
    await $.session.start(sessionStart);
    expectStockBoat((await draw($, 40)).glyphs);
    expect(journal.toasts).toHaveLength(0);
  });

  for (const [what, text, reason] of [
    ["invalid JSON", "{ not json", "not valid JSON"],
    ["a row narrower than the declared width", SPRITE.replace("███▶ ", "███▶"), `"right"[0].glyphs[1] is 4 wide, not 5`],
    ["an undefined palette key", SPRITE.replace("bbbe ", "bbbz "), `names "z"`],
    ["an unknown version", SPRITE.replace('"version":1', '"version":2'), `"version" must be 1`],
    ["a wide glyph", SPRITE.replace("███▶ ", "███\u{1f525} "), "not a single-column glyph"],
  ] as const) {
    test(`a malformed file (${what}) draws the stock boat and says why`, async ($, on) => {
      const { journal } = world(on, { preference: "on\n", sprite: text });
      await $.session.start(sessionStart);
      expectStockBoat((await draw($, 40)).glyphs);
      expect(journal.toasts).toHaveLength(1);
      // The reason follows a short label, so a standard-width terminal shows it whole.
      expect(journal.toasts[0]!.startsWith("Calm sprite ignored: ")).toBe(true);
      expect(journal.toasts[0]).toContain(reason);
    });
  }

  test("a sprite too wide for the row draws the full stock boat at that width", async ($, on) => {
    const wide = JSON.stringify({ version: 1, width: 20, right: [{ glyphs: ["█".repeat(20), "▀".repeat(20)] }] });
    const { journal } = world(on, { preference: "on\n", sprite: wide });
    await $.session.start(sessionStart);
    const narrow = await draw($, 14);
    expect(narrow.raster.rows).toBe(2);
    expectStockBoat(narrow.glyphs);
    // The same file fits a wider row and draws there in the theme's boat color.
    const roomy = await draw($, 40);
    expect(roomy.glyphs[0]!.startsWith("█".repeat(20))).toBe(true);
    expect(roomy.foregrounds[0]![0]).toBe(0xd77757);
    expect(journal.toasts).toHaveLength(0);
  });

  test("turning Calm on rereads the file, and a malformed one is named in the toggle notice", async ($, on) => {
    const { files, journal } = world(on, { sprite: "{ not json" });
    await $.session.start(sessionStart);
    // Calm is off, so the bad file is not announced at load.
    expect(journal.toasts).toHaveLength(0);
    await $.command.run(calmCommand());
    expect(journal.toasts.at(-1)).toMatch(/^Calm sprite ignored: the file is not valid JSON/);
    expectStockBoat((await draw($, 40)).glyphs);
    // Fixing the file and toggling off and on picks it up without a restart.
    files.set("/fm/home/config/calm-sprite.json", SPRITE);
    await $.command.run(calmCommand());
    await $.command.run(calmCommand());
    expect(journal.toasts.at(-1)).toBe("Calm on");
    expect((await draw($, 40)).glyphs[1]!.startsWith(RIGHT_WALK)).toBe(true);
  });
});
