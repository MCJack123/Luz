# Luz
An extremely *light* Lua compression algorithm.

## Usage
```
Usage: luz [options] <input> [output]
Options:
  -c      Force compression
  -d      Force decompression
  -m      Minify before compression (experimental)
  -r      Run compressed file
  --help  Show this help
```

## Format Details
The compression algorithm revolves around using Huffman coding on the language tokens itself, rather than on the bytes in the source file.

- A static Huffman tree, computed using a large data set of Lua files, is used to code Lua keywords, operators, and commonly-used identifiers, strings and numbers. Each token in the file is stored as one code (plus extra data for identifiers/strings/numbers).
- Other identifiers are stored in a dynamic, per-file Huffman tree, which uses canonical codes to reduce the size of the tree in the file. Identifiers are coded with a special ":name" token code, and then the code for the identifier tree.
- Numbers are stored using one of two ways:
  - If the number is an integer, it's stored using big-endian base 128 (7-bit) variable-length quantity format. This value is proceeded by a `0` bit, followed by a sign bit. (VarUInt indicates the number is stored without those two bits.)
  - Otherwise, it's stored as an exponent and mantissa, with a `1` bit, then the sign for the number, then *the sign for the exponent* (this value must be un/re-biased for float conversion), then the exponent in base 8 (3-bit) VLQ, then the mantissa in base 128 (7-bit) VLQ.
- Strings are stored in a global string table, which is simply a concatenation of all strings in the file in binary (i.e. not quoted) form. This table is DEFLATEd when stored in the file. Strings are coded with a special ":string" token code, and then the length of the string in the table using the same number format for integers.

A Luz file consists of the following parts:
- Magic number (5 bytes): Currently `\eLuzQ`, but the `Q` may change in the future for newer versions.
- String table (DEFLATE block): The concatenation of all string constants (that aren't in the static tree), DEFLATEd. The end of the block is padded to the next byte.
- Number of identifiers (VarUInt): The number of extra identifiers in the identifier tree.
- Identifier list (list of 6-bit strings): Each identifier in the tree is stored as a "Base64-decoded" string, where each character in the identifier is encoded using 6 bits according to the Base64 standard, but with character 62 being `_`, and character 63 being the stop character.
- Identifier tree code length size (4 bits): The number of bits in each code length in the following list.
- Identifier tree code lengths (list of *n*-bit numbers): The length of each entry in the previous identifier list using canonical Huffman codes.
- Token list (list of Huffman codes): A series of Huffman codes storing the Lua tokens in the file. These decode using the tables supplied in the `token_*.lua` files. Certain tokens have extra data after:
  - `:name`: The code is followed by another Huffman code indexing the identifier tree, which specifies which identifier to use.
  - `:string`: The code is followed by a VarUInt specifying the length of the string. The decoder should read that many characters from the string table at the current position, and advance the read position forward to the end of the run.
  - `:number`: The code is followed by a number encoded as specified above.
- The end of the file is marked by a `:end` code.

## Performance
*(Early tests - these may improve over time.)*

### [Phoenix Kernel](https://phoenix.madefor.cc)
- Original source: 380,108 bytes
- Minified source (luamin): 231,149 bytes (-39.2%)
- Original, Luz-compressed: 82,321 bytes (**-78.3%**)
- Minified, Luz-compressed: 83,905 bytes (**-77.9%**)

### [LibDeflate](https://github.com/SafeteeWow/LibDeflate)
- Original source: 129,887 bytes
- Minified source (luamin): 33,381 bytes (-74.3%)
- Original, Luz-compressed: 19,012 bytes (**-85.4%**)
- Minified, Luz-compressed: 16,912 bytes (**-87.0%**)
