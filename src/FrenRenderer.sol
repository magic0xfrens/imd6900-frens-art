// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FrenArtIndex} from "./FrenArtIndex.sol";

/// @title FrenRenderer - draws an IMD6900 fren on chain
/// @notice The art lives in seven data contracts, FrenArtChunk1..7 (FrenArtIndex says what is where), each checked by
///         its code hash on every art read (the constructor only stores addresses):
///  - a 256-colour palette;
///  - each character's 13 faces (each distinct face kept once; a table points each character's faces at them);
///  - 3 lab coats, one fitted to each character;
///  - 2 hats;
///  - 15 items, held in the right hand;
///  - 10 backgrounds.
///
///  A fren is drawn on an 84x84 canvas: its background through a window picked by its seed, then its face, coat, hat and
///  item. The lens, coat shades and shirt are palette slots filled from its combo. Out comes an 8-bit bitmap inside an
///  SVG, and metadata with its traits. Nothing here changes after deploy. The reference the tests check against byte for
///  byte is export_v2.py in the art kit; its output is `script/frens/art/`.
/// @dev Layer format: x0 y0 w h, then per row (count, index) runs over w pixels; index 0 is see-through.
///      A combo (24 bits): character 0-1 | face 2-5 | eye 6-7 | coat 8-9 | shirt 10-12 | hat 13-14 | background 15-18 |
///      item 19-22. Layers: the faces, then coat0..2, hat0..1, item0..14, bg0..9.
contract FrenRenderer {
    using Strings for uint256;

    uint256 internal constant N = 84; // the canvas
    uint256 internal constant CX = 18; // where the canvas sits in the layers' 120x120 space (3px right of centre: room for the held item)
    uint256 internal constant CY = 26;
    uint256 internal constant SLOT0 = 244; // 244..248 coat shades, 249 shirt, 250..251 lens
    uint256 internal constant FACES = 13; // per character
    uint256 internal constant REST = 30; // the layers after the faces: 3 coats, 2 hats, 15 items, 10 backgrounds

    uint256 internal constant PENDING_BG = 3; // an unrevealed fren: greyed out, in front of the machine wall
    uint256 internal constant PENDING_FRAMES = 4; // …flicking through this many random frens, the swarm still deciding

    uint256 public constant faceLayers = FrenArtIndex.FACE_LAYERS;
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

    /* ── metadata ─────────────────────────────────────────────────── */

    function tokenURI(uint256 tokenId, uint24 combo, uint256 seed) external view returns (string memory) {
        string memory image = _svg(bmp(combo, seed));
        string memory json = string.concat(
            '{"name":"IMD6900 Fren #',
            tokenId.toString(),
            '","description":"One of 2222 IMD6900 frens, built layer by layer by five agents in the IMD swarm and backed by a floor of IMD6900. Drawn on chain.","image":"',
            image,
            '","attributes":',
            attributes(combo),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice A fren minted but not revealed yet: greyed out, flicking through random frens, until the agents' job lands
    function pendingURI(uint256 tokenId) external view returns (string memory) {
        string memory json = string.concat(
            '{"name":"IMD6900 Fren #',
            tokenId.toString(),
            '","description":"Minted, not revealed yet: five agents in the IMD swarm are building this fren, and it reveals on chain when their job lands. Backed by the floor all along.","image":"',
            _svgFrames(_bmpOf(unrevealed(tokenId), PENDING_FRAMES, true)),
            '","attributes":[{"trait_type":"Status","value":"Unrevealed"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice An unrevealed fren's pixels: PENDING_FRAMES random frens (any trait at any value: the swarm hasn't
    ///         decided yet) in front of the machine wall, seen through a window its token id picks, stacked top to bottom.
    ///         pendingURI shows them greyed out, one after another.
    function unrevealed(uint256 tokenId) public view returns (bytes memory sheet) {
        uint8[8] memory none;
        uint256 seed = uint256(keccak256(abi.encode(tokenId)));
        bytes memory back = new bytes(N * N);
        _draw(back, _entry(faceLayers + 20 + PENDING_BG), -int256(seed % 37), -int256((seed >> 8) % 37), none, 0);
        sheet = new bytes(N * N * PENDING_FRAMES);
        for (uint256 k; k < PENDING_FRAMES; ++k) {
            bytes memory cv = bytes.concat(back); // the wall is drawn once, each frame starts from a copy
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 combo = (r % 3) | ((r >> 8) % FACES) << 2 | ((r >> 16) % 4) << 6 | ((r >> 24) % 3) << 8
                | ((r >> 32) % 6) << 10 | ((r >> 40) % 3) << 13 | ((r >> 48) % 16) << 19;
            _fren(cv, uint24(combo));
            _copy(sheet, k * N * N, cv, 0, N * N);
        }
    }

    /// @dev Frames stacked in one bitmap, shown one at a time on an uneven beat: a fren that won't sit still
    function _svgFrames(bytes memory bitmap) internal pure returns (string memory) {
        string memory h = (N * PENDING_FRAMES).toString();
        return string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 84 84" width="840" height="840">',
                        '<image width="84" height="', h, '" style="image-rendering:pixelated" href="data:image/bmp;base64,',
                        Base64.encode(bitmap),
                        '"><animate attributeName="y" values="0;-84;-168;-252;-84" keyTimes="0;0.22;0.37;0.64;0.83" ',
                        'dur="1.3s" calcMode="discrete" repeatCount="indefinite"/></image></svg>'
                    )
                )
            )
        );
    }

    function attributes(uint24 combo) public pure returns (string memory) {
        return string.concat(
            '[{"trait_type":"Character","value":"',
            _name(combo & 3, "Cyborg Pepe|Mumu|Bobo"),
            '"},{"trait_type":"Face","value":"',
            _name((combo >> 2) & 15, "Classic|Happy|Angry|Feels Bad|Grinding|Chill|Grumpy|Giga Happy|Cooked|Comfy|Special|Scientist|Laser Eyes"),
            '"},{"trait_type":"Eye","value":"',
            _name((combo >> 6) & 3, "Green|Red|Cyan|Gold"),
            '"},{"trait_type":"Coat","value":"',
            _name((combo >> 8) & 3, "White|Black|Gold"),
            '"},{"trait_type":"Shirt","value":"',
            _name((combo >> 10) & 7, "Blue|Red|Green|Black|Orange|Purple"),
            '"},{"trait_type":"Hat","value":"',
            _name((combo >> 13) & 3, "None|Mumu Hat|Bobo Hat"),
            string.concat(
                '"},{"trait_type":"Item","value":"',
                _name(
                    (combo >> 19) & 15,
                    "None|Flask|Ray Gun|Magnet|Magnifier|Dynamite|Extinguisher|Bomb|10 Paddle|0 Paddle|Drink|Wrench|Green Lightsaber|Red Lightsaber|Light Bulb|Bunsen Burner"
                ),
                '"},{"trait_type":"Background","value":"',
                _name(
                    (combo >> 15) & 15,
                    "Matrix Green|Matrix Red|Matrix Gold|Machine Wall|Machine Wall Dark|Machine Wall Lit|Machine Wall II|Terminal|Circuit Board|Lab Goo"
                ),
                '"}]'
            )
        );
    }

    /// @dev The i-th name of a |-separated list.
    function _name(uint256 i, string memory list) internal pure returns (string memory) {
        bytes memory b = bytes(list);
        uint256 start;
        uint256 k;
        for (uint256 j; j <= b.length; ++j) {
            if (j == b.length || b[j] == "|") {
                if (k == i) {
                    bytes memory out = new bytes(j - start);
                    for (uint256 m; m < out.length; ++m) out[m] = b[start + m];
                    return string(out);
                }
                ++k;
                start = j + 1;
            }
        }
        return "";
    }

    /* ── the bitmap ──────────────────────────────────────────────── */

    /// @dev A bitmap as the pixelated SVG data URI a token's image is.
    function _svg(bytes memory bitmap) internal pure returns (string memory) {
        return string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 84 84" width="840" height="840">',
                        '<image width="84" height="84" style="image-rendering:pixelated" href="data:image/bmp;base64,',
                        Base64.encode(bitmap),
                        '"/></svg>'
                    )
                )
            )
        );
    }

    /// @notice The fren as an 84x84 8-bit bitmap (the palette's colours), rows bottom-up as BMP has them.
    function bmp(uint24 combo, uint256 seed) public view returns (bytes memory) {
        return _bmpOf(canvas(combo, seed), 1, false);
    }

    /// @dev `frames` canvases stacked top to bottom as one bitmap; `grey`: the palette turned to its own luminance, dimmed
    function _bmpOf(bytes memory cv, uint256 frames, bool grey) internal view returns (bytes memory out) {
        bytes memory pal = _entry(FrenArtIndex.LAYERS);
        uint256 rows = N * frames;
        out = new bytes(54 + 1024 + N * rows);
        // BITMAPFILEHEADER + BITMAPINFOHEADER, little endian
        _le(out, 0, 0x4d42, 2); // "BM"
        _le(out, 2, out.length, 4);
        _le(out, 10, 54 + 1024, 4);
        _le(out, 14, 40, 4);
        _le(out, 18, N, 4);
        _le(out, 22, rows, 4);
        _le(out, 26, 1, 2);
        _le(out, 28, 8, 2);
        _le(out, 34, N * rows, 4);
        _le(out, 46, 256, 4);
        _copy(out, 54, pal, 0, 1024);
        if (grey) {
            for (uint256 i; i < 256; ++i) {
                uint256 b = 54 + i * 4; // B G R 0
                uint256 l = (uint256(uint8(out[b + 2])) * 77 + uint256(uint8(out[b + 1])) * 150 + uint256(uint8(out[b])) * 29) >> 8;
                bytes1 v = bytes1(uint8(l * 3 / 5));
                (out[b], out[b + 1], out[b + 2]) = (v, v, v);
            }
        }
        for (uint256 y; y < rows; ++y) _copy(out, 54 + 1024 + y * N, cv, (rows - 1 - y) * N, N);
    }

    /// @notice The fren's pixels, palette indices, top row first.
    function canvas(uint24 combo, uint256 seed) public view returns (bytes memory cv) {
        uint256 ch = combo & 3;
        uint256 face = (combo >> 2) & 15;
        uint256 bg = (combo >> 15) & 15;
        if (ch > 2 || face >= FACES || bg >= 10) revert Missing();
        bytes memory t = FrenArtIndex.TABLES;
        // the slots: coat shades (5), shirt, lens (2)
        uint8[8] memory slot;
        uint256 coat = (combo >> 8) & 3;
        uint256 shirt = (combo >> 10) & 7;
        uint256 eye = (combo >> 6) & 3;
        if (coat > 2 || shirt > 5) revert Missing();
        for (uint256 i; i < 5; ++i) slot[i] = uint8(t[8 + coat * 5 + i]);
        slot[5] = uint8(t[23 + shirt]);
        slot[6] = uint8(t[eye * 2]);
        slot[7] = uint8(t[eye * 2 + 1]);

        cv = new bytes(N * N);
        _draw(cv, _entry(faceLayers + 20 + bg), -int256(seed % 37), -int256((seed >> 8) % 37), slot, 0);
        _fren(cv, combo);
    }

    /// @dev The fren itself, over whatever `cv` holds: face, coat, hat, item, its slots filled from its combo
    function _fren(bytes memory cv, uint24 combo) internal view {
        uint256 ch = combo & 3;
        uint256 face = (combo >> 2) & 15;
        bytes memory t = FrenArtIndex.TABLES;
        uint8[8] memory slot;
        uint256 coat = (combo >> 8) & 3;
        uint256 shirt = (combo >> 10) & 7;
        uint256 eye = (combo >> 6) & 3;
        for (uint256 i; i < 5; ++i) slot[i] = uint8(t[8 + coat * 5 + i]);
        slot[5] = uint8(t[23 + shirt]);
        slot[6] = uint8(t[eye * 2]);
        slot[7] = uint8(t[eye * 2 + 1]);
        uint256 f = faceLayers;
        _draw(cv, _entry(uint8(FrenArtIndex.FACE_TABLE[ch * FACES + face])), -int256(CX), -int256(CY), slot, 0);
        _draw(cv, _entry(f + ch), -int256(CX), -int256(CY), slot, 0);
        uint256 hat = (combo >> 13) & 3;
        if (hat > 2) revert Missing();
        if (hat != 0) _draw(cv, _entry(f + 2 + hat), -int256(CX), -int256(CY), slot, 0);
        uint256 item = (combo >> 19) & 15;
        if (item != 0) _draw(cv, _entry(f + 4 + item), -int256(CX), -int256(CY), slot, 0);
    }

    /// @dev `mono`: when not 0, every pixel the layer covers takes that one colour (a silhouette)
    function _draw(bytes memory cv, bytes memory d, int256 dx, int256 dy, uint8[8] memory slot, uint8 mono) internal pure {
        uint256 x0 = uint8(d[0]);
        uint256 y0 = uint8(d[1]);
        uint256 w = uint8(d[2]);
        uint256 h = uint8(d[3]);
        uint256 i = 4;
        for (uint256 y = y0; y < y0 + h; ++y) {
            int256 yy = int256(y) + dy;
            bool row = yy >= 0 && yy < int256(N);
            for (uint256 x = x0; x < x0 + w;) {
                uint256 n = uint8(d[i]);
                uint256 c = uint8(d[i + 1]);
                i += 2;
                if (c != 0 && row) {
                    if (mono != 0) c = mono;
                    else if (c >= SLOT0 && c < SLOT0 + 8) c = slot[c - SLOT0];
                    int256 a = int256(x) + dx;
                    int256 b = a + int256(n);
                    if (a < 0) a = 0;
                    if (b > int256(N)) b = int256(N);
                    uint256 base = uint256(yy) * N;
                    for (int256 xx = a; xx < b; ++xx) cv[base + uint256(xx)] = bytes1(uint8(c));
                }
                x += n;
            }
        }
    }

    /// @dev `len` bytes of `from` (from `fromAt`) into `to` (at `at`)
    function _copy(bytes memory to, uint256 at, bytes memory from, uint256 fromAt, uint256 len) internal pure {
        assembly ("memory-safe") {
            mcopy(add(add(to, 32), at), add(add(from, 32), fromAt), len)
        }
    }

    function _le(bytes memory b, uint256 at, uint256 v, uint256 n) internal pure {
        for (uint256 i; i < n; ++i) b[at + i] = bytes1(uint8(v >> (8 * i)));
    }

    /* ── reading the art back (see FrenArtIndex) ── */

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
}
