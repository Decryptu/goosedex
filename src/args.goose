// The command line: a few flags, and Pokemon named by every other argument.

namespace cli;

enum Flag { Name, Help, Random, Shiny, HideName }

struct Args {
    help: bool = false,
    random: bool = false,
    shiny: bool = false,
    hide_name: bool = false,
    name_count: i64 = 0,
}

fn flag(arg: const u8[:]) -> Flag {
    if arg == "-h" || arg == "--help" { return Flag.Help; }
    if arg == "-r" || arg == "--random" || arg == "random" { return Flag.Random; }
    if arg == "-s" || arg == "--shiny" { return Flag.Shiny; }
    if arg == "--hide-name" { return Flag.HideName; }
    return Flag.Name;
}

// Every argument that is not a flag names a Pokemon.
fn is_name(arg: const u8[:]) -> bool {
    match flag(arg) { Name => true, _ => false }
}

fn add(a: Args&, arg: const u8[:]) {
    match flag(arg) {
        Name => { a.name_count++; },
        Help => { a.help = true; },
        Random => { a.random = true; },
        Shiny => { a.shiny = true; },
        HideName => { a.hide_name = true; },
    }
}

fn parse<T>(argv: T[:]) -> Args {
    var result = Args { .. };
    for arg in argv { add(result, arg); }
    return result;
}

let USAGE = """
    goosedex - Display Pokemon sprites in your terminal

    Usage: goosedex [options] [pokemon...]

    Options:
      -r, --random, random    Display a random pokemon (1/128 chance for shiny)
      -s, --shiny             Show shiny variant
      --hide-name             Don't print the Pokemon's name
      -h, --help              Show this help

    Examples:
      goosedex pikachu
      goosedex pikachu --shiny --hide-name
      goosedex bulbasaur charmander squirtle
      goosedex random
      goosedex --random
      goosedex 1 25 150

    """;
