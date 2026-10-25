import std;
namespace inflate;
// A raw DEFLATE (RFC 1951) decoder: the counterpart of tools/deflate.goose.
// Huffman codes up to FAST_BITS long resolve with one table lookup, longer
// ones by walking the canonical code a bit at a time.

let FAST_BITS = 10;

struct Huffman {
    counts: u16[16],              // codes of each length
    symbols: u16[320],            // symbols in canonical code order
    fast: u16[1 << FAST_BITS],    // length << 9 | symbol for a short code, 0 for a long one
}

const LEN_BASE: u16[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                           35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: u8[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE: u16[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                            8193, 12289, 16385, 24577];
const DIST_EXTRA: u8[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
// The order in which a dynamic block lists its code length code lengths.
const CLEN_ORDER: u8[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

// Builds the decoding tables for `lengths[i]`, the code length of symbol i.
fn build(h: Huffman&, lengths: u8[:]) {
    h.counts = [0; 16];
    h.fast = [0; 1 << FAST_BITS];
    for l in lengths { h.counts[l] += 1; }
    h.counts[0] = 0;
    var offsets: u16[16] = [0; 16];
    var next_code: u32[16] = [0; 16];
    var code: u32 = 0;
    for len in 1..16 {
        offsets[len] = offsets[len - 1] + h.counts[len - 1];
        code = (code + h.counts[len - 1]) << 1;
        next_code[len] = code;
    }
    offsets[0] = 0;
    for l, sym in lengths {
        guard l != 0;
        h.symbols[offsets[l]] = sym as u16;
        offsets[l] += 1;
        let c = next_code[l];
        next_code[l] += 1;
        guard l <= FAST_BITS;
        // Codes are sent most significant bit first, so the table is indexed
        // by the code reversed, with every filler for the unused high bits.
        var rev: u32 = 0;
        for i in l { rev |= ((c >> i) & 1) << (l - 1 - i); }
        let entry = (l as u16) << 9 | sym as u16;
        var k = rev;
        while k < (1 << FAST_BITS) {
            h.fast[k] = entry;
            k += 1 << l;
        }
    }
}

// Decodes `src` onto `out`, any growable u8 array, until the final block ends
// or `out` holds `limit` bytes. Returns false for malformed input.
fn inflate<B>(src: const u8[:], out: B&, limit: i64) -> bool {
    var pos = 0;
    var buf: u64 = 0;
    var nbits: i64 = 0;
    var lit = default<Huffman>();
    var dist = default<Huffman>();

    // Keeps at least 32 bits buffered; past the end of `src` it feeds zeros,
    // which a well-formed stream never reaches.
    inline fn refill() {
        while nbits <= 56 {
            if pos < src.len { buf |= (src[pos] as u64) << nbits; }
            pos++;
            nbits += 8;
        }
    }
    inline fn take(n: i64) -> u32 {
        if nbits < n { refill(); }
        let v = (buf & ((1 << n) - 1)) as! u32;
        buf >>= n;
        nbits -= n;
        return v;
    }
    fn decode(h: Huffman&) -> i64 {
        if nbits < 15 { refill(); }
        let e = h.fast[buf & ((1 << FAST_BITS) - 1)];
        if e != 0 {
            let l = (e >> 9) as i64;
            buf >>= l;
            nbits -= l;
            return e & 511;
        }
        var code: i64 = 0;
        var first: i64 = 0;
        var index: i64 = 0;
        for len in 1..16 {
            code |= ((buf >> (len - 1)) & 1) as! i64;
            let count = h.counts[len] as i64;
            if code - first < count {
                buf >>= len;
                nbits -= len;
                return h.symbols[index + code - first];
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        return -1;
    }

    var lengths: u8[320] = [0; 320];
    loop {
        if out.len >= limit { return true; }
        if pos > src.len + 8 { return false; }
        let last = take(1) == 1;
        let kind = take(2);
        if kind == 0 {
            // Stored: byte aligned, a length and its complement, raw bytes.
            buf >>= nbits % 8;
            nbits -= nbits % 8;
            let len = take(16);
            if take(16) != (~len & 0xFFFF) { return false; }
            for i in len {
                if out.len >= limit { return true; }
                out.push(take(8) as! u8);
            }
        } else {
            if kind == 1 {
                for i in 0..144 { lengths[i] = 8; }
                for i in 144..256 { lengths[i] = 9; }
                for i in 256..280 { lengths[i] = 7; }
                for i in 280..288 { lengths[i] = 8; }
                build(lit, lengths[..288]);
                for i in 0..30 { lengths[i] = 5; }
                build(dist, lengths[..30]);
            } else if kind == 2 {
                let hlit = take(5) as i64 + 257;
                let hdist = take(5) as i64 + 1;
                let hclen = take(4) as i64 + 4;
                var clens: u8[19] = [0; 19];
                for i in hclen { clens[CLEN_ORDER[i]] = take(3) as! u8; }
                build(lit, clens);
                var n = 0;
                while n < hlit + hdist {
                    let sym = decode(lit);
                    if sym < 0 { return false; }
                    if sym < 16 {
                        lengths[n] = sym as! u8;
                        n++;
                        continue;
                    }
                    var fill: u8 = 0;
                    var times: i64 = 0;
                    if sym == 16 {
                        if n == 0 { return false; }
                        fill = lengths[n - 1];
                        times = 3 + take(2) as i64;
                    } else if sym == 17 {
                        times = 3 + take(3) as i64;
                    } else {
                        times = 11 + take(7) as i64;
                    }
                    if n + times > hlit + hdist { return false; }
                    for i in times { lengths[n + i] = fill; }
                    n += times;
                }
                build(lit, lengths[..hlit]);
                build(dist, lengths[hlit..hlit + hdist]);
            } else {
                return false;
            }
            loop {
                let sym = decode(lit);
                if sym < 256 {
                    if sym < 0 { return false; }
                    if out.len >= limit { return true; }
                    out.push(sym as! u8);
                    continue;
                }
                if sym == 256 { break; }
                if sym > 285 { return false; }
                let li = sym - 257;
                let len = LEN_BASE[li] as i64 + take(LEN_EXTRA[li]);
                let ds = decode(dist);
                if ds < 0 || ds > 29 { return false; }
                let d = DIST_BASE[ds] as i64 + take(DIST_EXTRA[ds]);
                if d > out.len { return false; }
                let end = min(out.len + len, limit);
                while out.len < end { out.push(out[out.len - d]); }
                if out.len >= limit { return true; }
            }
        }
        if last { return true; }
    }
}
