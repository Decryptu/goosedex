// A raw DEFLATE (RFC 1951) compressor, tuned like zlib's level 9: hash chains
// with lazy matching, then whichever of a dynamic Huffman, fixed Huffman or
// stored block is smallest. src/inflate.goose decodes what it writes.

import std;
namespace deflate;

let WINDOW = 32768;
let HASH_BITS = 15;
let MIN_MATCH = 3;
let MAX_MATCH = 258;
let MAX_CHAIN = 4096;
let GOOD_MATCH = 32;    // a match this long already searches a quarter of the chain
let TOO_FAR = 4096;     // a 3-byte match further back than this costs more than its literals

// A literal when dist is 0, otherwise a match of `len` bytes `dist` back.
struct Token { len: u16, dist: u16 }

const LEN_BASE: u16[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                           35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: u8[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE: u16[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                            8193, 12289, 16385, 24577];
const DIST_EXTRA: u8[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CLEN_ORDER: u8[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

fn len_code(len: i64) -> i64 {
    var c = 28;
    while LEN_BASE[c] > len { c--; }
    return c;
}

fn dist_code(dist: i64) -> i64 {
    var c = 29;
    while DIST_BASE[c] > dist { c--; }
    return c;
}

// Fills `lengths` with Huffman code lengths for `freqs`, none longer than
// `limit`. Frequencies are halved until the longest code fits. At least two
// symbols get a code, as inflaters expect of a tree.
fn huffman_lengths(freqs: u32[:], limit: i64, lengths: u8[:]) {
    assert(freqs.len == lengths.len);
    fill(lengths, 0);
    var f: u64[>..] = [];
    for x in freqs { f.push(x); }
    var used = count(f) { it > 0 };
    for i in f.len {
        if used >= 2 { break; }
        if f[i] == 0 {
            f[i] = 1;
            used++;
        }
    }
    var syms: i64[>..] = [];
    for x, s in f { if x > 0 { syms.push(s); } }
    stable_sort(syms) { a, b => f[a] < f[b] };
    let m = syms.len;
    loop {
        // Two queues: the sorted leaves, and the merged nodes, which come out
        // in order of weight by construction.
        var weight: u64[>..] = [];
        for s in syms { weight.push(f[s]); }
        var parent: i64[>..] = [];
        push_n(parent, 0, 2 * m - 1);
        var leaf = 0;
        var node = m;
        for next in m..2 * m - 1 {
            var pair: i64[2] = [0, 0];
            for k in 2 {
                if leaf < m && (node == next || weight[leaf] <= weight[node]) {
                    pair[k] = leaf;
                    leaf++;
                } else {
                    pair[k] = node;
                    node++;
                }
            }
            weight.push(weight[pair[0]] + weight[pair[1]]);
            parent[pair[0]] = next;
            parent[pair[1]] = next;
        }
        var depth: i64[>..] = [];
        push_n(depth, 0, 2 * m - 1);
        var longest = 0;
        var k = 2 * m - 3;
        while k >= 0 {
            depth[k] = depth[parent[k]] + 1;
            longest = max(longest, depth[k]);
            k--;
        }
        if longest <= limit {
            for s, i in syms { lengths[s] = depth[i] as! u8; }
            return;
        }
        for s in syms { f[s] = (f[s] >> 1) | 1; }
        stable_sort(syms) { a, b => f[a] < f[b] };
    }
}

// Canonical codes for `lengths`, bit-reversed for an LSB-first writer.
fn canonical_codes(lengths: u8[:], codes: u16[:]) {
    var counts: u16[16] = [0; 16];
    for l in lengths { counts[l] += 1; }
    counts[0] = 0;
    var next_code: u32[16] = [0; 16];
    var code: u32 = 0;
    for len in 1..16 {
        code = (code + counts[len - 1]) << 1;
        next_code[len] = code;
    }
    for l, sym in lengths {
        guard l != 0;
        let c = next_code[l];
        next_code[l] += 1;
        var rev: u32 = 0;
        for i in l { rev |= ((c >> i) & 1) << (l - 1 - i); }
        codes[sym] = rev as! u16;
    }
}

// Appends `data` to `out` as one raw DEFLATE stream with a block boundary at
// `split`. No match crosses it, so an inflater that stops at `split` stops at
// the end of a match, while the second part may still refer back into the first.
fn deflate(out: u8[>..]&, data: const u8[:], split: i64) {
    let n = data.len;
    var head: i32[1 << HASH_BITS] = [-1; 1 << HASH_BITS];
    var prev: i32[>..] = [];
    push_n(prev, -1, n);
    var tokens: Token[>..<] = [];
    var bitbuf: u64 = 0;
    var nbits: i64 = 0;

    fn put(v: u64, count: i64) {
        bitbuf |= v << nbits;
        nbits += count;
        while nbits >= 8 {
            out.push((bitbuf & 0xFF) as! u8);
            bitbuf >>= 8;
            nbits -= 8;
        }
    }

    fn insert(i: i64) {
        guard i + 2 < n;
        let h = ((data[i] as u32 << 10) ^ (data[i + 1] as u32 << 5) ^ data[i + 2]) & ((1 << HASH_BITS) - 1);
        prev[i] = head[h];
        head[h] = i as i32;
    }

    // The longest match at `i` that is longer than `better_than` and ends by
    // `end`, as length and distance; 0, 0 if there is none.
    fn longest_match(i: i64, end: i64, better_than: i64) -> i64, i64 {
        let max_len = min(MAX_MATCH, end - i);
        if max_len < MIN_MATCH || better_than >= max_len { return 0, 0; }
        var chain = if better_than >= GOOD_MATCH { MAX_CHAIN / 4 } else { MAX_CHAIN };
        var best = max(better_than, MIN_MATCH - 1);
        var best_dist = 0;
        var cand = prev[i] as i64;
        while cand >= 0 && i - cand <= WINDOW && chain > 0 {
            if data[cand + best] == data[i + best] && data[cand] == data[i] {
                var l = 1;
                while l < max_len && data[cand + l] == data[i + l] { l++; }
                if l > best {
                    best = l;
                    best_dist = i - cand;
                    if l == max_len { break; }
                }
            }
            cand = prev[cand];
            chain--;
        }
        if best_dist == 0 || (best == MIN_MATCH && best_dist > TOO_FAR) { return 0, 0; }
        return best, best_dist;
    }

    // Lazy matching: a match is taken only if the next position has no longer one.
    fn tokenize(start: i64, end: i64) {
        tokens.clear();
        var i = start;
        var pending = false;
        var prev_len = 0;
        var prev_dist = 0;
        while i < end {
            insert(i);
            let len, dist = longest_match(i, end, prev_len);
            if prev_len >= MIN_MATCH && len == 0 {
                tokens.push(Token { len: prev_len as! u16, dist: prev_dist as! u16 });
                let stop = i - 1 + prev_len;
                for j in i + 1..stop { insert(j); }
                i = stop;
                pending = false;
                prev_len = 0;
                continue;
            }
            if pending { tokens.push(Token { len: data[i - 1], dist: 0 }); }
            pending = true;
            prev_len = len;
            prev_dist = dist;
            i++;
        }
        if pending { tokens.push(Token { len: data[end - 1], dist: 0 }); }
    }

    fn write_block(start: i64, end: i64, last: bool) {
        tokenize(start, end);
        var lit_freq: u32[286] = [0; 286];
        var dist_freq: u32[30] = [0; 30];
        for t in tokens {
            if t.dist == 0 {
                lit_freq[t.len] += 1;
            } else {
                lit_freq[257 + len_code(t.len)] += 1;
                dist_freq[dist_code(t.dist)] += 1;
            }
        }
        lit_freq[256] = 1;

        var lit_len: u8[286] = [0; 286];
        var dist_len: u8[30] = [0; 30];
        huffman_lengths(lit_freq, 15, lit_len);
        huffman_lengths(dist_freq, 15, dist_len);
        var hlit = 286;
        while lit_len[hlit - 1] == 0 { hlit--; }
        var hdist = 30;
        while hdist > 1 && dist_len[hdist - 1] == 0 { hdist--; }

        // Run-length code the lengths of both trees as one sequence.
        var all: u8[316] = [0; 316];
        for i in hlit { all[i] = lit_len[i]; }
        for i in hdist { all[hlit + i] = dist_len[i]; }
        let total = hlit + hdist;
        var runs: Token[>..<] = [];     // len is the code length symbol, dist its extra bits
        var i = 0;
        while i < total {
            let l = all[i];
            var run = 1;
            while i + run < total && all[i + run] == l { run++; }
            if l == 0 && run >= 3 {
                let k = min(run, 138);
                if k >= 11 { runs.push(Token { len: 18, dist: (k - 11) as! u16 }); }
                else { runs.push(Token { len: 17, dist: (k - 3) as! u16 }); }
                i += k;
            } else if l != 0 && run >= 4 {
                runs.push(Token { len: l, dist: 0 });
                let k = min(run - 1, 6);
                runs.push(Token { len: 16, dist: (k - 3) as! u16 });
                i += 1 + k;
            } else {
                runs.push(Token { len: l, dist: 0 });
                i++;
            }
        }
        var clen_freq: u32[19] = [0; 19];
        for r in runs { clen_freq[r.len] += 1; }
        var clen_len: u8[19] = [0; 19];
        huffman_lengths(clen_freq, 7, clen_len);
        var hclen = 19;
        while hclen > 4 && clen_len[CLEN_ORDER[hclen - 1]] == 0 { hclen--; }

        // Sizes in bits, to pick the cheapest block type.
        var dynamic_bits = 3 + 14 + 3 * hclen;
        for r in runs {
            dynamic_bits += clen_len[r.len];
            if r.len == 16 { dynamic_bits += 2; }
            if r.len == 17 { dynamic_bits += 3; }
            if r.len == 18 { dynamic_bits += 7; }
        }
        var fixed_bits = 3 + 7;
        dynamic_bits += lit_len[256];
        for t in tokens {
            if t.dist == 0 {
                dynamic_bits += lit_len[t.len];
                fixed_bits += if t.len < 144 { 8 } else { 9 };
            } else {
                let lc = len_code(t.len);
                let dc = dist_code(t.dist);
                let extra = LEN_EXTRA[lc] as i64 + DIST_EXTRA[dc];
                dynamic_bits += lit_len[257 + lc] as i64 + dist_len[dc] + extra;
                fixed_bits += (if lc < 23 { 7 } else { 8 }) + 5 + extra;
            }
        }
        let len = end - start;
        let stored_bits = 8 * (len + 5 * (len / 65535 + 1)) + 10;

        if stored_bits < dynamic_bits && stored_bits < fixed_bits {
            var at = start;
            loop {
                let chunk = min(end - at, 65535);
                let final = last && at + chunk == end;
                put(if final { 1 } else { 0 }, 3);
                if nbits > 0 { put(0, 8 - nbits); }
                put(chunk as! u64, 16);
                put((~chunk & 0xFFFF) as! u64, 16);
                for b in data[at..at + chunk] { out.push(b); }
                at += chunk;
                if at == end { break; }
            }
            return;
        }

        var lit_code: u16[288] = [0; 288];
        var dist_code_of: u16[30] = [0; 30];
        if fixed_bits <= dynamic_bits {
            put(if last { 3 } else { 2 }, 3);
            var fixed_len: u8[288] = [0; 288];
            for k in 0..144 { fixed_len[k] = 8; }
            for k in 144..256 { fixed_len[k] = 9; }
            for k in 256..280 { fixed_len[k] = 7; }
            for k in 280..288 { fixed_len[k] = 8; }
            for k in 286 { lit_len[k] = fixed_len[k]; }
            canonical_codes(fixed_len, lit_code);
            for k in 30 { dist_len[k] = 5; }
            canonical_codes(dist_len, dist_code_of);
        } else {
            put(if last { 5 } else { 4 }, 3);
            put((hlit - 257) as! u64, 5);
            put((hdist - 1) as! u64, 5);
            put((hclen - 4) as! u64, 4);
            for k in hclen { put(clen_len[CLEN_ORDER[k]], 3); }
            var clen_code: u16[19] = [0; 19];
            canonical_codes(clen_len, clen_code);
            for r in runs {
                put(clen_code[r.len], clen_len[r.len]);
                if r.len == 16 { put(r.dist, 2); }
                if r.len == 17 { put(r.dist, 3); }
                if r.len == 18 { put(r.dist, 7); }
            }
            canonical_codes(lit_len, lit_code[..286]);
            canonical_codes(dist_len, dist_code_of);
        }
        for t in tokens {
            if t.dist == 0 {
                put(lit_code[t.len], lit_len[t.len]);
            } else {
                let lc = len_code(t.len);
                let dc = dist_code(t.dist);
                put(lit_code[257 + lc], lit_len[257 + lc]);
                put(t.len - LEN_BASE[lc], LEN_EXTRA[lc]);
                put(dist_code_of[dc], dist_len[dc]);
                put(t.dist - DIST_BASE[dc], DIST_EXTRA[dc]);
            }
        }
        put(lit_code[256], lit_len[256]);
    }

    write_block(0, split, split == n);
    if split < n { write_block(split, n, true); }
    if nbits > 0 { put(0, 8 - nbits); }
}
