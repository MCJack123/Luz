# Luz
An extremely *light* Lua compression algorithm.

## Usage
```
Usage: luz [options] <input> [output]
Options:
  -c       Force compression
  -d       Force decompression
  -l <num> Compression level (0-15)
  -m       Minify before compression (experimental)
  -r       Run compressed file
  --help   Show this help
```

## Format Details
The compression algorithm revolves around using Huffman coding + LZ77 on the language tokens itself, rather than on the bytes in the source file.

- A static Huffman tree, computed using a large data set of Lua files, is used to code Lua keywords, operators, and commonly-used identifiers, strings and numbers. Each token in the file is stored as one code (plus extra data for identifiers/strings/numbers).
- Other identifiers are stored in a dynamic, per-file Huffman tree, which uses canonical codes to reduce the size of the tree in the file. Identifiers are coded with a special ":name" token code, and then the code for the identifier tree.
- Numbers are stored using one of two ways:
  - If the number is an integer, it's stored using big-endian base 128 (7-bit) variable-length quantity format. This value is proceeded by a `0` bit, followed by a sign bit. (VarUInt indicates the number is stored without those two bits.)
  - Otherwise, it's stored as an exponent and mantissa, with a `1` bit, then the sign for the number, then *the sign for the exponent* (this value must be un/re-biased for float conversion), then the exponent in base 8 (3-bit) VLQ, then the mantissa in base 128 (7-bit) VLQ.
- Strings are stored in a global string table, which is simply a concatenation of all strings in the file in binary (i.e. not quoted) form. This table is DEFLATEd when stored in the file. Strings are coded with a special ":string" token code, and then the length of the string in the table using the same number format for integers.
- The entire list of tokens is then passed through an LZ77 filter, which deduplicates repeated tokens.

A Luz file consists of the following parts:
- Magic number (4 bytes): `\eLuz`
- Version (1 byte): Currently `Q`, but this may change with alternate tree structures.
- String table (DEFLATE block): The concatenation of all string constants (that aren't in the static tree), DEFLATEd. The end of the block is padded to the next byte.
- Identifier list (DEFLATEd list of 6-bit strings): Each identifier in the tree is stored as a "Base64-decoded" string, where each character in the identifier is encoded using 6 bits according to the Base64 standard, but with character 62 being `_`, and character 63 being the stop character. All identifiers are concatenated into an 8-bit string and then DEFLATEd. The end of the block is padded to the next byte.
- Distance tree code length size (4 bits): The number of bits in each code length in the following list.
  - If this value is 0, an additional bit follows, indicating how many entries there are in the tree (0/1). If 1, a VarUInt with the index follows. In both cases, the length list does not exist.
- Distance tree code lengths (RLE, 30 codes of *size* bits): A run-length encoded list of code lengths using canonical Huffman codes, coded 0-29, with each entry having a length code the specified format, followed by the code length itself:2, 6, 22, 86, 342, 1366, 5462
  - For 1 repetition: bits 000
  - For 2-5 repetitions: bits 001 + (*n* - 2) in 2 bits
  - For 6-21 repetitions: bits 010 + (*n* - 6) in 4 bits
  - For 22-85 repetitions: bits 011 + (*n* - 22) in 6 bits
  - For 86-341 repetitions: bits 100 + (*n* - 86) in 8 bits
  - For 342-1365 repetitions: bits 101 + (*n* - 342) in 10 bits
  - For 1366-5461 repetitions: bits 110 + (*n* - 1366) in 12 bits
  - For 5462-21845 repetitions: bits 111 + (*n* - 5462) in 14 bits
    - Note that it is *highly* unlikely that the last two will ever end up used in a file.
- Identifier tree code length size (4 bits): The number of bits in each code length in the following list. See above for the caveats if this value is 0.
- Identifier tree code lengths (RLE, *n* codes of *size* bits): An RLE'd list of lengths of each entry in the identifier list, using the same format as the distance tree. This tree is only used until the next tree is read.
- Token list (list of Huffman codes): A series of Huffman codes storing the Lua tokens (or LZ77 repetitions) in the file. These decode using the tables supplied in the `token_*.lua` files. Certain tokens have extra data after:
  - `:name`: The code is followed by another Huffman code indexing the identifier tree, which specifies which identifier to use. If the identifier tree only has one entry, no bits follow.
  - `:string`: The code is followed by a VarUInt specifying the length of the string. The decoder should read that many characters from the string table at the current position, and advance the read position forward to the end of the run.
  - `:number`: The code is followed by a number encoded as specified above.
  - `:repeat<N>`: The code is followed by a number of extra bits determined by *N*, and then a distance Huffman code + extra bits
    - The length and distance codes follow the same format as DEFLATE's distance codes, with the length code adding 2 to the result.
    - If the repeated area ends in a `function` token, the identifier tree follows the LZ77 codes.
- The end of the file is marked by a `:end` code.

## Performance
*(Early tests - these may improve over time.)*

### [Phoenix Kernel](https://phoenix.madefor.cc)
- Original source: 380,108 bytes
- Minified source (luamin): 231,149 bytes (-39.2%)
- Original, Luz-compressed: 48,897 bytes (**-87.1%**)
  - Decompressed: 259,416 bytes
- Minified, Luz-compressed: 49,476 bytes (**-87.0%**)
  - Decompressed: 230,943 bytes
- Minified, Gzip-compressed: 46,968 bytes

### [LibDeflate](https://github.com/SafeteeWow/LibDeflate)
- Original source: 129,887 bytes
- Minified source (luamin): 33,381 bytes (-74.3%)
- Original, Luz-compressed: 12,900 bytes (**-90.1%**)
  - Decompressed: 62,811 bytes
- Minified, Luz-compressed: 12,199 bytes (**-90.6%**)
  - Decompressed: 33,373 bytes
- Minified, Gzip-compressed: 11,125 bytes
