#!/usr/bin/env python3
# Derives this repository's FrenRenderer from the frens' own renderer (IDMD-Strategy-frens src/frens/FrenRenderer.sol),
# so the two always draw and describe every fren the same: only where the art is read from changes (seven chunk
# contracts, checked by code hash, instead of one SSTORE2 contract per layer). Also refreshes test/ref, the copy the
# tests compare against.
#   python3 script/art/derive_renderer.py [path to the frens' FrenRenderer.sol]
import os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..", "..")
src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Documents/GitHub/IDMD-Strategy-frens/src/frens/FrenRenderer.sol")
ref = open(src).read()

# the reference, renamed, for the tests
r = ref.replace("contract FrenArt {", "contract FrenArtRef {").replace("contract FrenRenderer {", "contract FrenRendererRef {")
r = r.replace("// SPDX-License-Identifier: MIT", "// SPDX-License-Identifier: MIT\n// The renderer the frens launch with (IDMD-Strategy-frens src/frens/FrenRenderer.sol), renamed: the tests check\n// the chunk renderer draws and describes every fren exactly as this one does.", 1)
open(os.path.join(root, "test", "ref", "FrenRendererRef.sol"), "w").write(r)

s = ref
a, b = s.index("/// @title FrenArt"), s.index("/// @title FrenRenderer")
s = s[:a] + s[b:]
s = s.replace('import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";',
              'import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";\nimport {FrenArtIndex} from "./FrenArtIndex.sol";')
s = s.replace("/// @notice The art lives in data contracts (see FrenArt):",
              "/// @notice The art lives in seven data contracts, FrenArtChunk1..7 (FrenArtIndex says what is where), each checked by\n///         its code hash on every art read (the constructor only stores addresses):")
state = s[s.index("    address public immutable palette;"):s.index("    /* ── metadata")]
s = s.replace(state, '''    uint256 public constant faceLayers = FrenArtIndex.FACE_LAYERS;
    uint8 public constant shadow = FrenArtIndex.SHADOW; // the palette's dark lens green (the art's own)

    address public immutable chunk1;
    address public immutable chunk2;
    address public immutable chunk3;
    address public immutable chunk4;
    address public immutable chunk5;
    address public immutable chunk6;
    address public immutable chunk7;

    error Missing();
    error BadArt();

    /// @dev Static arguments only (IMD's launch): the seven FrenArtChunk contracts, in order. Nothing is read here, so it
    ///      deploys anywhere (IMD's admission deploys a launch on a fresh chain, where the earlier launches' chunks don't
    ///      exist); every read checks its chunk's code hash instead (_entry), so this can only ever draw this art.
    constructor(address c1, address c2, address c3, address c4, address c5, address c6, address c7) {
        (chunk1, chunk2, chunk3, chunk4, chunk5, chunk6, chunk7) = (c1, c2, c3, c4, c5, c6, c7);
    }

''')
def entries(s):
    # `_read(_layers[<expr>])` -> `_entry(<expr>)`, matching brackets: <expr> can hold its own [...] and (...)
    out, n, key = [], 0, "_read(_layers["
    while True:
        i = s.find(key)
        if i < 0:
            return "".join(out) + s, n
        j, depth = i + len(key), 1
        while depth:
            depth += {"[": 1, "]": -1}.get(s[j], 0)
            j += 1
        assert s[j] == ")", s[i:j + 1]
        out.append(s[:i] + "_entry(" + s[i + len(key):j - 1] + ")")
        s, n = s[j + 1:], n + 1
s, n1 = entries(s)
s = s.replace("_read(palette)", "_entry(FrenArtIndex.LAYERS)")  # the palette: the entry after the layers
s = s.replace("bytes memory t = _tables;", "bytes memory t = FrenArtIndex.TABLES;")
s = s.replace("_faceTable[", "FrenArtIndex.FACE_TABLE[")
old_read = s[s.index("    /* ── reading the art back (see FrenArt) ── */"):s.rindex("}")]
s = s.replace(old_read, '''    /* ── reading the art back (see FrenArtIndex) ── */

    /// @dev Entry `i` (a layer, or the palette after them): its bytes, cut from its chunk's code
    function _entry(uint256 i) internal view returns (bytes memory data) {
        bytes memory ix = FrenArtIndex.INDEX;
        uint256 c;
        uint256 off;
        uint256 len;
        assembly ("memory-safe") {
            let w := mload(add(add(ix, 32), mul(i, 5)))
            c := byte(0, w)
            off := and(shr(232, w), 0xffff) // bytes 1-2
            len := and(shr(216, w), 0xffff) // bytes 3-4
        }
        address p = [chunk1, chunk2, chunk3, chunk4, chunk5, chunk6, chunk7][c];
        bytes memory hashes = FrenArtIndex.CHUNK_HASHES;
        bytes32 want;
        assembly ("memory-safe") {
            want := mload(add(add(hashes, 32), mul(c, 32)))
        }
        if (p.codehash != want) revert BadArt(); // exactly the art FrenArtIndex was generated from, or nothing
        data = new bytes(len);
        if ((FrenArtIndex.FRAMED >> c) & 1 == 0) {
            if (p.code.length < 1 + off + len) revert Missing();
            assembly ("memory-safe") {
                extcodecopy(p, add(data, 32), add(1, off), len)
            }
            return data;
        }
        // framed: art byte j sits at 1 + (j / 32) * 33 + 1 + j % 32, after each frame's PUSH32 byte
        uint256 first = off / 32;
        uint256 frames = (off + len - 1) / 32 - first + 1;
        if (p.code.length < 1 + (first + frames) * 33) revert Missing();
        bytes memory raw = new bytes(frames * 33);
        bytes memory flat = new bytes(frames * 32);
        assembly ("memory-safe") {
            extcodecopy(p, add(raw, 32), add(1, mul(first, 33)), mul(frames, 33))
            for { let k := 0 } lt(k, frames) { k := add(k, 1) } {
                mcopy(add(add(flat, 32), mul(k, 32)), add(add(raw, 33), mul(k, 33)), 32)
            }
            mcopy(add(data, 32), add(add(flat, 32), mod(off, 32)), len)
        }
    }
''')
for leftover in ("_read(", "_layers", "_tables", "_faceTable", "palette_"):
    assert leftover not in s, f"left over: {leftover}"
open(os.path.join(root, "src", "FrenRenderer.sol"), "w").write(s)
print("src/FrenRenderer.sol and test/ref/FrenRendererRef.sol from", src, f"({n1} layer reads)")
