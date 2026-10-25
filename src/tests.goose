// Unit tests, run with `make test`.

import std;
import inflate;
import args;
import sprites;
import gen.embedded_sprites;

var failures = 0;

fn check(ok: bool, what: const u8[:]) {
    if !ok {
        print("FAIL: ", what);
        failures++;
    }
}

fn slug_of(query: const u8[:]) -> const u8[:] {
    let p = sprites::find_pokemon(query);
    guard p else { return ""; }
    return sprites::text(p.slug);
}

fn test_cli() {
    let argv = ["pikachu", "--shiny", "random", "--hide-name", "25"];
    let a = cli::parse(argv);
    check(a.name_count == 2, "two names");
    check(a.shiny && a.random && a.hide_name && !a.help, "flags");
    check(cli::is_name("pikachu"), "pikachu is a name");
    check(!cli::is_name("-s"), "-s is a flag");
    check(starts_with(cli::USAGE, "goosedex - ") && ends_with(cli::USAGE, "goosedex 1 25 150\n"), "usage");
}

fn test_lookup() {
    check(slug_of("25") == "pikachu", "25 is pikachu");
    let a = sprites::find_pokemon("25");
    let b = sprites::find_pokemon("PIKACHU");
    check(a && b && a .== b, "number and name find the same entry");
    check(slug_of("charizard-mega-x") == "charizard-mega-x", "slug lookup");
    check(slug_of("Charizard (Mega X)") == "charizard-mega-x", "form name lookup");
    check(slug_of("Mr. Mime") == "mr-mime", "name lookup");
    let last = sprites::find_pokemon("1025");
    check(last && last.idx == 1025, "1025");
    check(!sprites::find_pokemon("0"), "0 is not found");
    check(!sprites::find_pokemon("1026"), "1026 is not found");
    check(slug_of("000025") == "pikachu", "leading zeros");
    check(!sprites::find_pokemon("2_5"), "only digits make a number");
    check(!sprites::find_pokemon("99999999999999999999"), "a number past i64");
    check(!sprites::find_pokemon("definitely-not-a-pokemon"), "unknown name");
}

fn test_render() {
    let pikachu = sprites::find_pokemon("pikachu");
    assert(pikachu);
    var regular: u8[>..] = [];
    sprites::write(regular, pikachu, false, false);
    var shiny: u8[>..] = [];
    sprites::write(shiny, pikachu, true, true);

    check(starts_with(regular, "Pikachu\n     \x1b[38;2;0;0;0m▄\x1b[48;2;65;65;65m▀\x1b[48;2;0;0;0m▀\x1b[49m         ▄▄  \x1b[0m\n"),
          "pikachu's first line");
    let art = regular["Pikachu\n".len..];
    check(count(art) { it == '\n' } == count(shiny) { it == '\n' }, "both variants have the same height");
    check(art != shiny, "the variants differ");
    check(ends_with(shiny, "\x1b[0m\n"), "colors reset at the end");
}

// Every embedded stream inflates to the lengths its table entry records, and
// each sprite's header accounts for exactly its bytes.
fn test_all_sprites() {
    for i in ENTRY_COUNT {
        let p .= pokemon(i);
        var buf: u8[>..] = [];
        let total = p.regular_len as i64 + p.shiny_len;
        let ok = inflate::inflate(sprites::text(p.sprites), buf, total);
        check(ok && buf.len == total, str(sprites::text(p.slug), " inflates"));
        guard buf.len == total;
        for part in [buf[..p.regular_len], buf[p.regular_len..]] {
            let palette_len = part[2] | (part[3] as i64) << 8;
            let width: i64 = if palette_len > 255 { 4 } else { 2 };
            let size = 4 + 3 * palette_len + width * part[0] * part[1];
            check(part.len == size, str(sprites::text(p.slug), " sprite size"));
        }
    }
}

fn main() {
    test_cli();
    test_lookup();
    test_render();
    test_all_sprites();
    if failures > 0 {
        print(failures, " test(s) failed");
        exit(1);
    }
    print("all tests passed");
}
