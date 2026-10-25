// goosedex: Pokemon sprites in your terminal, embedded in the binary.

import std;
import os;
import args;
import sprites;

// The C library's generator, seeded from OS entropy: no file to open, unlike
// os.random_seed, which reads /dev/urandom.
extern fn arc4random() -> u32;

fn main() {
    // On macOS the runtime opens each data stack's memory on its first use,
    // with a fault that costs more than drawing a sprite. Parsing in a scope
    // of its own hands the arguments' stack, already open, to the output.
    let a = block {
        var text: u8[>..] = [];
        read_args(text);
        var parsed = cli::Args { .. };
        each_arg(text) { cli::add(parsed, it); };
        parsed
    };

    if a.help || (!a.random && a.name_count == 0) {
        write_stdout(cli::USAGE);
        return;
    }

    // Everything goes into one buffer, which leaves in a single write.
    var out: u8[>..] = [];

    if a.random {
        let pokemon, shiny = sprites::random_pokemon(random_seed64());
        sprites::write(out, pokemon, shiny || a.shiny, a.hide_name);
        write_stdout(out);
        return;
    }

    var text: u8[>..] = [];
    read_args(text);
    var status = 0;
    each_arg(text) { name =>
        guard cli::is_name(name);
        let pokemon = sprites::find_pokemon(name);
        guard pokemon else {
            write_stdout(out);
            out.clear();
            write_stderr(str("Pokemon '", name, "' not found.\n"));
            status = 1;
        }
        sprites::write(out, pokemon, a.shiny, a.hide_name);
    };
    write_stdout(out);
    if status != 0 { exit(status); }
}

// The arguments after the program's name, NUL-separated: os.args() would take
// a data stack for the text and another for the slices into it.
fn read_args(text: u8[>..]&) {
    for i in 1..arg_count() {
        if i > 1 { text.push(0); }
        arg(i, text);
    }
}

fn each_arg<F>(text: const u8[:]) {
    if arg_count() > 1 { each_split(text, 0) { F(it); }; }
}

fn random_seed64() -> u64 {
    (arc4random() as u64) << 32 | arc4random()
}
