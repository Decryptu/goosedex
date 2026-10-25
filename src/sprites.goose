// Pokemon lookup and display, over the tables tools/generate_sprites.goose
// writes to gen/embedded_sprites.goose.

import std;
import inflate;
import gen.embedded_sprites;

namespace sprites;

fn text(span: Span) -> const u8[:] {
    DATA[span.start..span.start + span.len]
}

fn find_pokemon(query: const u8[:]) -> const Pokemon? {
    let digits = all(query) { it >= '0' && it <= '9' };
    if query.len > 0 && digits {
        let n, ok = parse_int(query);
        if !ok || n == 0 || n > POKEMON_COUNT { return null; }
        return pokemon(n - 1);
    }

    if query.len > 64 { return null; }
    var lower: u8[..64] = [];
    lower.append(query);
    to_lower(lower);
    var lo = 0;
    var hi = KEY_COUNT;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if compare(text(key(mid).key), lower) < 0 { lo = mid + 1; } else { hi = mid; }
    }
    if lo == KEY_COUNT || text(key(lo).key) != lower { return null; }
    return pokemon(key(lo).index);
}

fn random_pokemon(seed: u64) -> const Pokemon&, bool {
    var r = rng { seed };
    let shiny = r.rand_int(128) == 0;
    return pokemon(r.rand_int(POKEMON_COUNT)), shiny;
}

fn write(out: u8[>..]&, pokemon: const Pokemon&, shiny: bool, hide_name: bool) {
    if !hide_name {
        out.append(text(pokemon.name));
        out.push('\n');
    }

    let start: i64 = if shiny { pokemon.regular_len } else { 0 };
    let len: i64 = if shiny { pokemon.shiny_len } else { pokemon.regular_len };
    var sprites: u8[>..] = [];
    let ok = inflate::inflate(text(pokemon.sprites), sprites, start + len);
    assert(ok && sprites.len == start + len);
    render(out, sprites[start..start + len]);
}

// Draws an encoded sprite (layout documented in tools/generate_sprites.goose)
// with half blocks, sending only the SGR changes each cell needs.
fn render(out: u8[>..]&, sprite: const u8[:]) {
    let width = sprite[0];
    let height = sprite[1];
    let palette_len = sprite[2] | (sprite[3] as i64) << 8;
    let palette = sprite[4..4 + 3 * palette_len];
    let cells = sprite[4 + palette.len..];
    let wide = palette_len > 255;

    // Palette indices, where 0 is the terminal default.
    var fg = 0;
    var bg = 0;
    var i = 0;
    for y in height {
        for x in width {
            let top = pixel(cells, i, wide);
            let bottom = pixel(cells, i + 1, wide);
            i += 2;

            // Opaque tops use ▀ so their color lands in fg; a lone bottom pixel uses ▄.
            // A space only shows its background, so it keeps whatever foreground is active.
            let want_fg = if top != 0 { top } else if bottom != 0 { bottom } else { fg };
            let want_bg = if top != 0 { bottom } else { 0 };

            if want_fg != fg || want_bg != bg {
                out.append("\x1b[");
                if want_fg != fg {
                    put_color(out, '3', palette, want_fg);
                    if want_bg != bg { out.push(';'); }
                    fg = want_fg;
                }
                if want_bg != bg {
                    if want_bg == 0 { out.append("49"); }
                    else { put_color(out, '4', palette, want_bg); }
                    bg = want_bg;
                }
                out.push('m');
            }
            if top != 0 { out.append("▀"); }
            else if bottom != 0 { out.append("▄"); }
            else { out.push(' '); }
        }
        // Resetting before the newline keeps a set background from bleeding into
        // scrolled lines, and keeps each line self-contained for tools that print
        // sprites beside other text.
        if fg != 0 || bg != 0 { out.append("\x1b[0m"); }
        fg = 0;
        bg = 0;
        out.push('\n');
    }
}

fn pixel(cells: const u8[:], i: i64, wide: bool) -> i64 {
    if wide { cells[2 * i] | (cells[2 * i + 1] as i64) << 8 } else { cells[i] }
}

// Appends `38;2;r;g;b`, or `48;...` for layer '4'.
fn put_color(out: u8[>..]&, layer: u8, palette: const u8[:], index: i64) {
    out.push(layer);
    out.append("8;2;");
    for channel in 3 {
        if channel > 0 { out.push(';'); }
        let c = palette[3 * (index - 1) + channel];
        if c >= 100 { out.push('0' + c / 100); }
        if c >= 10 { out.push('0' + c / 10 % 10); }
        out.push('0' + c % 10);
    }
}
